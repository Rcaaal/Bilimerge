import "dart:convert";
import "dart:io";
import "package:path_provider/path_provider.dart";
import "../models/bili_video.dart";
import "../models/export_record.dart";
import "export_service.dart";

/// 导出队列状态（可序列化，用于崩溃恢复）
class ExportQueueState {
  final List<String> pendingPaths;     // 待导出的 folderPath 列表
  final String? currentPath;           // 当前正在导出的文件夹路径
  final List<String> completedPaths;   // 已完成的文件夹路径
  final List<String> failedPaths;      // 失败的文件夹路径
  final int totalCount;

  ExportQueueState({
    required this.pendingPaths,
    this.currentPath,
    required this.completedPaths,
    required this.failedPaths,
    required this.totalCount,
  });

  int get completedCount => completedPaths.length;
  int get failedCount => failedPaths.length;

  bool get isComplete => pendingPaths.isEmpty && currentPath == null;
  double get progress => totalCount > 0 ? completedCount / totalCount : 0;

  Map<String, dynamic> toJson() => {
        "pendingPaths": pendingPaths,
        "currentPath": currentPath,
        "completedPaths": completedPaths,
        "failedPaths": failedPaths,
        "totalCount": totalCount,
      };

  factory ExportQueueState.fromJson(Map<String, dynamic> json) => ExportQueueState(
        pendingPaths: List<String>.from(json["pendingPaths"] ?? []),
        currentPath: json["currentPath"],
        completedPaths: List<String>.from(json["completedPaths"] ?? []),
        failedPaths: List<String>.from(json["failedPaths"] ?? []),
        totalCount: json["totalCount"] ?? 0,
      );

  ExportQueueState copyWith({
    List<String>? pendingPaths,
    String? currentPath,
    bool clearCurrent = false,
    List<String>? completedPaths,
    List<String>? failedPaths,
  }) =>
      ExportQueueState(
        pendingPaths: pendingPaths ?? this.pendingPaths,
        currentPath: clearCurrent ? null : (currentPath ?? this.currentPath),
        completedPaths: completedPaths ?? this.completedPaths,
        failedPaths: failedPaths ?? this.failedPaths,
        totalCount: totalCount,
      );
}

/// 导出进度回调
typedef ExportProgressCallback = void Function(
    ExportQueueState state, String currentFileName, String statusText);

/// 增强的导出服务：队列 + 进度 + 断点续传
class ExportQueueService {
  static ExportQueueState? _lastState;
  static bool _isRunning = false;

  /// 检查是否有未完成的导出（用于崩溃恢复）
  static Future<ExportQueueState?> getIncompleteState() async {
    await _loadState();
    if (_lastState == null || _lastState!.isComplete) return null;
    return _lastState;
  }

  /// 清除保存的队列状态
  static Future<void> clearState() async {
    _lastState = null;
    await _saveState(null);
  }

  /// 开始批量导出
  /// [videos] 待导出视频列表
  /// [onProgress] 进度回调
  /// [customDir] 自定义导出目录
  static Future<List<ExportResult>> startBatchExport({
    required List<BiliVideo> videos,
    ExportProgressCallback? onProgress,
    String? customDir,
  }) async {
    if (_isRunning) throw Exception("导出任务正在进行中");
    _isRunning = true;

    // 初始化队列状态
    final allPaths = videos.map((v) => v.folderPath).toList();
    _lastState = ExportQueueState(
      pendingPaths: allPaths,
      completedPaths: [],
      failedPaths: [],
      totalCount: allPaths.length,
    );
    await _saveState(_lastState);

    final results = <ExportResult>[];
    final pendingList = List<BiliVideo>.from(videos);

    for (int i = 0; i < pendingList.length; i++) {
      if (!_isRunning) break; // 被取消

      final video = pendingList[i];
      _lastState = _lastState!.copyWith(
        pendingPaths: _lastState!.pendingPaths.where((p) => p != video.folderPath).toList(),
        currentPath: video.folderPath,
      );
      await _saveState(_lastState);

      // 回调进度
      onProgress?.call(
        _lastState!,
        video.exportFileName,
        "正在导出 (${i + 1}/${pendingList.length}): ${video.title}",
      );

      // 执行导出
      ExportResult result;
      try {
        result = await ExportService.exportVideo(video, customDir: customDir);
      } catch (e) {
        result = ExportResult(false, error: "导出异常: $e");
      }

      results.add(result);

      if (result.success) {
        _lastState = _lastState!.copyWith(
          completedPaths: [..._lastState!.completedPaths, video.folderPath],
          clearCurrent: true,
        );
      } else {
        _lastState = _lastState!.copyWith(
          failedPaths: [..._lastState!.failedPaths, video.folderPath],
          clearCurrent: true,
        );
      }
      await _saveState(_lastState);
    }

    _isRunning = false;
    if (_lastState!.isComplete) {
      await clearState();
    }
    return results;
  }

  /// 取消导出
  static void cancelExport() {
    _isRunning = false;
  }

  /// 清除失败记录并重试失败的导出
  static Future<void> retryFailed(List<BiliVideo> allVideos) async {
    if (_lastState == null) return;
    final failedPaths = Set<String>.from(_lastState!.failedPaths);
    final completedPaths = Set<String>.from(_lastState!.completedPaths);

    // 找出失败和未处理的视频
    final toRetry = allVideos.where((v) =>
        failedPaths.contains(v.folderPath) ||
        (!completedPaths.contains(v.folderPath) &&
            !failedPaths.contains(v.folderPath)));

    _lastState = ExportQueueState(
      pendingPaths: toRetry.map((v) => v.folderPath).toList(),
      completedPaths: completedPaths.toList(),
      failedPaths: [],
      totalCount: toRetry.length + completedPaths.length,
    );
    await _saveState(_lastState);
  }

  /// 丢弃崩溃时正在导出的文件，重新从它开始
  static Future<void> discardCurrentAndResume() async {
    if (_lastState == null || _lastState!.currentPath == null) return;
    final current = _lastState!.currentPath!;

    // 尝试删除崩溃时可能产生的半成品文件
    try {
      final outDir = await ExportService.getExportDirectory();
      final dir = Directory(outDir);
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is File && f.path.contains(current.replaceAll(RegExp(r'[<>:"/\\|?*]'), ""))) {
            await f.delete();
          }
        }
      }
    } catch (_) {}

    // 把 current 放回 pending 头部，从头重新导出
    _lastState = _lastState!.copyWith(
      pendingPaths: [current, ..._lastState!.pendingPaths],
      clearCurrent: true,
    );
    await _saveState(_lastState);
  }

  // ---- 状态持久化 ----
  static Future<void> _saveState(ExportQueueState? state) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File("${dir.path}/BiliExportQueue.json");
      if (state == null) {
        if (await f.exists()) await f.delete();
        return;
      }
      await f.writeAsString(jsonEncode(state.toJson()));
    } catch (_) {}
  }

  static Future<void> _loadState() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File("${dir.path}/BiliExportQueue.json");
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString());
        _lastState = ExportQueueState.fromJson(data as Map<String, dynamic>);
      }
    } catch (_) {
      _lastState = null;
    }
  }
}
