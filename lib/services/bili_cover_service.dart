/// Bilibili API 封面下载服务
///
/// 扫描完成后，对缺少 cover.jpg 的视频通过 B 站公开 API 获取封面 URL 并下载。
/// 使用并发队列（3 并发 + 500ms 间隔）避免触发限流。
///
/// API: GET https://api.bilibili.com/x/web-interface/view
/// 参数: bvid=xxx 或 aid=xxx
/// 返回: { code: 0, data: { pic: "https://i0.hdslb.com/bfs/archive/xxx.jpg" } }
///
/// 跳过策略（自动下载时永久跳过，仅手动重下可恢复）：
/// - 已存在 cover.jpg → 跳过（已有封面）
/// - 已确认失效（API code != 0）→ 跳过，计入 invalidCount
/// - 曾网络错误下载失败 → 跳过，计入 failedSkippedCount
///
/// 手动重下：调用 [retrySingle] 单视频重试，成功则清理持久记录。
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";

import "../models/bili_video.dart";
import "failed_cover_service.dart";
import "invalid_cover_service.dart";

/// 封面下载队列的实时状态
///
/// [total] 只计数实际需要下载的视频（已过滤掉已失效/已失败/已有封面的），
/// 不包含已跳过项，所以主界面进度条显示的是真实下载进度。
///
/// 有三种结果：completed（成功）、failed（网络错误）、confirmedInvalid（API 失效）。
/// pending = total - completed - failed - confirmedInvalid。
class CoverDownloadStatus {
  final bool isRunning;
  final int total;
  final int completed;
  final int failed;
  final int confirmedInvalid; // 本次 API 确认失效数（影响 pending）
  final int invalidCount; // 总失效数（含之前跳过的，仅用于展示）
  final int failedSkippedCount; // 曾下载失败的视频数（计入跳过，不计入 total）
  final String? currentBvid;
  final String? currentTitle;

  const CoverDownloadStatus({
    this.isRunning = false,
    this.total = 0,
    this.completed = 0,
    this.failed = 0,
    this.confirmedInvalid = 0,
    this.invalidCount = 0,
    this.failedSkippedCount = 0,
    this.currentBvid,
    this.currentTitle,
  });

  /// 剩余待处理数
  int get pending => total - completed - failed - confirmedInvalid;

  /// 进度值（0.0 ~ 1.0），无任务时返回 null
  double? get progress {
    if (total == 0) return null;
    final done = completed + failed + confirmedInvalid;
    if (done == 0 && total > 0) return 0.0;
    return done / total;
  }
}

/// 封面下载队列服务
class BiliCoverService {
  static const int _concurrency = 3;
  static const int _batchIntervalMs = 500;

  /// 当前队列状态
  static CoverDownloadStatus status = const CoverDownloadStatus();

  /// 进度变化回调（UI 层绑定 setState）
  static VoidCallback? onProgressChanged;

  static bool _isRunning = false;
  static bool _cancelled = false;

  /// 启动封面下载队列
  ///
  /// 自动跳过：已有封面 / 已确认失效 / 曾下载失败的视频。
  /// [total] 只计数实际需要下载的视频。
  static Future<void> startDownload({
    required List<BiliVideo> videos,
    required String coversDir,
  }) async {
    if (_isRunning) return;
    _isRunning = true;
    _cancelled = false;

    // 加载已失效 + 已失败记录
    final invalidRecords = await InvalidCoverService.getAll();
    final invalidBvids = invalidRecords.map((r) => r.bvid).toSet();
    final failedRecords = await FailedCoverService.getAll();
    final failedBvids = failedRecords.map((r) => r.bvid).toSet();

    // 过滤：已有封面 / 失效 / 失败 的视频全部跳过
    final missing = <BiliVideo>[];
    int alreadyInvalid = 0;
    int alreadyFailed = 0;
    for (final v in videos) {
      if (_cancelled) break;
      final coverFile = File("$coversDir/${v.avidFolderName}/cover.jpg");
      if (coverFile.existsSync()) continue;
      // 检查 invalid 记录：用 bvid 或 avid（部分视频 bvid 为空）
      final invalidKey = v.bvid.isNotEmpty ? v.bvid : v.avid;
      if (invalidKey.isNotEmpty && invalidBvids.contains(invalidKey)) {
        alreadyInvalid++;
        continue;
      }
      // 检查 failed 记录：用 bvid 或 avid（部分视频 bvid 为空）
      final failKey = v.bvid.isNotEmpty ? v.bvid : v.avid;
      if (failKey.isNotEmpty && failedBvids.contains(failKey)) {
        alreadyFailed++;
        continue;
      }
      missing.add(v);
    }

    status = CoverDownloadStatus(
      total: missing.length,
      invalidCount: alreadyInvalid,
      failedSkippedCount: alreadyFailed,
      confirmedInvalid: 0,
      isRunning: true,
    );
    onProgressChanged?.call();

    if (missing.isEmpty) {
      status = CoverDownloadStatus(
        invalidCount: alreadyInvalid,
        failedSkippedCount: alreadyFailed,
        confirmedInvalid: 0,
        isRunning: false,
      );
      onProgressChanged?.call();
      _isRunning = false;
      return;
    }

    int completed = 0;
    int failed = 0;
    int newInvalid = 0;

    for (int i = 0; i < missing.length && !_cancelled; i += _concurrency) {
      final end = (i + _concurrency > missing.length)
          ? missing.length
          : i + _concurrency;
      final batch = missing.sublist(i, end);

      await Future.wait(batch.map((v) async {
        if (_cancelled) return;

        status = CoverDownloadStatus(
          total: missing.length,
          completed: completed,
          failed: failed,
          invalidCount: alreadyInvalid + newInvalid,
          confirmedInvalid: newInvalid,
          failedSkippedCount: alreadyFailed,
          currentBvid: v.bvid.isNotEmpty ? v.bvid : v.avid,
          currentTitle: v.title,
          isRunning: true,
        );
        onProgressChanged?.call();

        final result = await _downloadCover(v, coversDir);
        switch (result) {
          case _CoverResult.ok:
            completed++;
          case _CoverResult.confirmedInvalid:
            newInvalid++;
            // 同时写入 FailedCoverService，让用户能在「下载失败」标签页看到
            // 并手动重试（retrySingle 会同时清理两条记录）
            await FailedCoverService.markFailed(
              bvid: v.bvid.isNotEmpty ? v.bvid : v.avid,
              title: v.title,
              ownerName: v.ownerName,
              avidFolderName: v.avidFolderName,
            );
            // 不递增 failed — failed 仅反映真实网络错误数，
            // 与进度环「失败」统计一致
          case _CoverResult.networkError:
            await FailedCoverService.markFailed(
              bvid: v.bvid.isNotEmpty ? v.bvid : v.avid,
              title: v.title,
              ownerName: v.ownerName,
              avidFolderName: v.avidFolderName,
            );
            failed++;
        }
      }));

      status = CoverDownloadStatus(
        total: missing.length,
        completed: completed,
        failed: failed,
        invalidCount: alreadyInvalid + newInvalid,
        confirmedInvalid: newInvalid,
        failedSkippedCount: alreadyFailed,
        isRunning: true,
      );
      onProgressChanged?.call();

      if (end < missing.length && !_cancelled) {
        await Future.delayed(const Duration(milliseconds: _batchIntervalMs));
      }
    }

    status = CoverDownloadStatus(
      total: missing.length,
      completed: completed,
      failed: failed,
      invalidCount: alreadyInvalid + newInvalid,
      confirmedInvalid: newInvalid,
      failedSkippedCount: alreadyFailed,
      isRunning: false,
    );
    onProgressChanged?.call();
    _isRunning = false;
  }

  /// 手动重试单个视频封面下载
  ///
  /// 无论成功/失败，会清理 FailedCoverService 和 InvalidCoverService 中的记录，
  /// 重新判断状态。返回 true 表示封面下载成功，false 表示仍无有效封面。
  /// 成功后 UI 层应触发 setState 刷新封面。
  static Future<bool> retrySingle(BiliVideo video, String coversDir) async {
    final bvid = video.bvid.isNotEmpty ? video.bvid : video.avid;

    // 先清理旧记录
    await FailedCoverService.remove(bvid);
    await _removeFromInvalid(bvid);

    // 重新下载
    final result = await _downloadCover(video, coversDir);
    switch (result) {
      case _CoverResult.ok:
        return true; // 封面已写入
      case _CoverResult.confirmedInvalid:
        // 仍然失效，写回 FailedCoverService 保持可见可重试
        await FailedCoverService.markFailed(
          bvid: bvid,
          title: video.title,
          ownerName: video.ownerName,
          avidFolderName: video.avidFolderName,
        );
        return false;
      case _CoverResult.networkError:
        // 再次网络失败，重新写回 failed 列表
        await FailedCoverService.markFailed(
          bvid: bvid,
          title: video.title,
          ownerName: video.ownerName,
          avidFolderName: video.avidFolderName,
        );
        return false;
    }
  }

  /// 从 InvalidCoverService 中移除（retry 时调用）
  static Future<void> _removeFromInvalid(String bvid) async {
    await InvalidCoverService.remove(bvid);
  }

  static void cancel() {
    _cancelled = true;
    _isRunning = false;
    status = const CoverDownloadStatus(isRunning: false);
    onProgressChanged?.call();
  }

  /// 下载单个视频封面
  static Future<_CoverResult> _downloadCover(
    BiliVideo video,
    String coversDir,
  ) async {
    final client = HttpClient();
    try {
      client.userAgent =
          "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36";

      final idParam = video.bvid.isNotEmpty
          ? "bvid=${video.bvid}"
          : "aid=${video.avid}";
      final apiUri =
          Uri.parse("https://api.bilibili.com/x/web-interface/view?$idParam");
      final apiReq = await client.getUrl(apiUri);
      final apiRes = await apiReq.close();
      final body = await apiRes.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (json["code"] != 0 || json["data"] == null) {
        await InvalidCoverService.markInvalid(
          bvid: video.bvid.isNotEmpty ? video.bvid : video.avid,
          title: video.title,
          ownerName: video.ownerName,
          avidFolderName: video.avidFolderName,
        );
        return _CoverResult.confirmedInvalid;
      }

      final picUrl = (json["data"] as Map)["pic"] as String?;
      if (picUrl == null || picUrl.isEmpty) {
        await InvalidCoverService.markInvalid(
          bvid: video.bvid.isNotEmpty ? video.bvid : video.avid,
          title: video.title,
          ownerName: video.ownerName,
          avidFolderName: video.avidFolderName,
        );
        return _CoverResult.confirmedInvalid;
      }

      final imgUri = Uri.parse(picUrl);
      final imgReq = await client.getUrl(imgUri);
      final imgRes = await imgReq.close();

      final bytes = <int>[];
      await for (final chunk in imgRes) {
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) return _CoverResult.networkError;

      final dir = Directory("$coversDir/${video.avidFolderName}");
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await File("${dir.path}/cover.jpg").writeAsBytes(bytes);

      return _CoverResult.ok;
    } on SocketException {
      return _CoverResult.networkError;
    } on HttpException {
      return _CoverResult.networkError;
    } on FormatException {
      return _CoverResult.networkError;
    } catch (_) {
      return _CoverResult.networkError;
    } finally {
      client.close();
    }
  }

  static bool get isRunning => _isRunning;
}

enum _CoverResult { ok, confirmedInvalid, networkError }
