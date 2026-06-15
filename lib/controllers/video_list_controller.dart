// VideoListController — 剥离自 VideoListScreen 的业务逻辑与状态
//
// ChangeNotifier 模式，Screen 通过 addListener + setState 监听变化。
// 不导入 package:flutter/material.dart（仅 foundation.dart 的 ChangeNotifier）。
//
// 职责：扫描 / 排序 / 选择 / 待导出队列 / 导出流程 / 删除 / 播放 的状态与纯逻辑。
// 对话框、导航、FilePicker 等需要 BuildContext 的操作保留在 Screen。
import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path_provider/path_provider.dart";

import "../models/bili_video.dart";
import "../models/delete_result.dart";
import "../screens/video_list/sort_types.dart";
import "../services/bili_cover_service.dart";
import "../services/bili_parser.dart";
import "../services/delete_service.dart";
import "../services/diagnostic_log_service.dart";
import "../services/export_queue.dart";
import "../services/export_service.dart";
import "../services/settings_service.dart";
import "../services/shell_copy_service.dart";
import "../services/video_cache_service.dart";

// ─────────────────────────────────────────────────────────────
// 进度模型
// ─────────────────────────────────────────────────────────────

/// 导出进度（Screen 通过 ValueListenableBuilder 绑定）
class ExportProgress {
  final int done;
  final int total;
  final int skippedCount;
  final String currentFileName;
  final bool isCancelled;
  final Duration elapsed;

  const ExportProgress({
    this.done = 0,
    this.total = 0,
    this.skippedCount = 0,
    this.currentFileName = "",
    this.isCancelled = false,
    this.elapsed = Duration.zero,
  });

  double? get progress => total > 0 ? done / total : null;
  String get elapsedFormatted {
    final min = elapsed.inMinutes;
    final sec = elapsed.inSeconds % 60;
    return "${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}";
  }

  ExportProgress copyWith({
    int? done,
    int? total,
    int? skippedCount,
    String? currentFileName,
    bool? isCancelled,
    Duration? elapsed,
  }) =>
      ExportProgress(
        done: done ?? this.done,
        total: total ?? this.total,
        skippedCount: skippedCount ?? this.skippedCount,
        currentFileName: currentFileName ?? this.currentFileName,
        isCancelled: isCancelled ?? this.isCancelled,
        elapsed: elapsed ?? this.elapsed,
      );
}

/// Shizuku 仅扫描进度
class ScanProgress {
  final int done;
  final int total;
  final String currentFile;

  const ScanProgress({
    this.done = 0,
    this.total = 0,
    this.currentFile = "准备中...",
  });

  double? get progress => total > 0 ? done / total : null;

  ScanProgress copyWith({int? done, int? total, String? currentFile}) =>
      ScanProgress(
        done: done ?? this.done,
        total: total ?? this.total,
        currentFile: currentFile ?? this.currentFile,
      );
}

// ─────────────────────────────────────────────────────────────
// Controller
// ─────────────────────────────────────────────────────────────

class VideoListController extends ChangeNotifier {
  // ── 核心视频状态 ──────────────────────────────────────
  List<BiliVideo> _videos = [];
  bool _loading = false;
  String? _rootPath;
  String? _error;
  String? _diagnosticInfo;
  bool _exporting = false;
  bool _shizukuScanMode = false;
  String? _coverDir;

  // ── 导出追踪 ──────────────────────────────────────────
  Set<String> _exportedKeys = {};
  final Set<String> _pendingExportKeys = {};

  // ── 排序状态 ──────────────────────────────────────────
  SortField _sortField = SortField.date;
  SortOrder _sortOrder = SortOrder.desc;

  // ── 选择模式 ──────────────────────────────────────────
  bool _selectMode = false;
  final Set<int> _selected = {};

  // ── 导出进度（Screen 绑定的 ValueNotifier）───────────
  final ValueNotifier<ExportProgress> exportProgress =
      ValueNotifier(const ExportProgress());

  // ── 扫描进度（Screen 绑定的 ValueNotifier）───────────
  final ValueNotifier<ScanProgress> scanProgress =
      ValueNotifier(const ScanProgress());

  // ── Snackbar 桥接 ─────────────────────────────────────
  final ValueNotifier<String?> snackMessage = ValueNotifier(null);

  // ── 导出内部状态（被 executeExport 使用）─────────────
  bool exportCancelled = false;
  final List<String> _exportErrors = [];
  Stopwatch _exportStopwatch = Stopwatch();
  Timer? _exportTimer;

  // ────────────────────────────────────────────────────────
  // 计算属性
  // ────────────────────────────────────────────────────────

  // -- 源码访问器（返回实际集合，用于继承父类迭代）--
  List<BiliVideo> get videos => _videos;
  String? get rootPath => _rootPath;
  String? get error => _error;
  String? get diagnosticInfo => _diagnosticInfo;
  bool get loading => _loading;
  bool get exporting => _exporting;
  bool get shizukuScanMode => _shizukuScanMode;
  String? get coverDir => _coverDir;
  Set<String> get exportedKeys => _exportedKeys;
  bool get selectMode => _selectMode;

  // -- 推导属性 --
  bool get hasVideos => _videos.isNotEmpty;
  bool get hasError => _error != null;
  bool get isWelcome => _rootPath == null;
  int get videoCount => _videos.length;
  int get pendingCount => _pendingExportKeys.length;
  int get selectedCount => _selected.length;

  /// 排序后的视频列表（保持不可变视图）
  List<BiliVideo> get sortedVideos {
    var list = List<BiliVideo>.from(_videos);
    if (_sortField == SortField.exported) {
      final notExported =
          list.where((v) => !_exportedKeys.contains(exportKey(v))).toList();
      final exported =
          list.where((v) => _exportedKeys.contains(exportKey(v))).toList();
      notExported.sort(
          (a, b) => b.downloadTimestamp.compareTo(a.downloadTimestamp));
      exported.sort(
          (a, b) => b.downloadTimestamp.compareTo(a.downloadTimestamp));
      return notExported + exported;
    }
    int comp(BiliVideo a, BiliVideo b) {
      switch (_sortField) {
        case SortField.size:
          return a.totalBytes.compareTo(b.totalBytes);
        case SortField.date:
          return a.downloadTimestamp.compareTo(b.downloadTimestamp);
        case SortField.owner:
          return a.ownerName.compareTo(b.ownerName);
        case SortField.exported:
          return 0;
      }
    }
    list.sort(
        (a, b) => _sortOrder == SortOrder.asc ? comp(a, b) : comp(b, a));
    return list;
  }

  /// 已选择的视频列表
  List<BiliVideo> get selectedVideos =>
      _selected.map((i) => sortedVideos[i]).toList();

  /// 待导出队列的视频列表
  List<BiliVideo> get pendingExportVideos =>
      _videos.where((v) => _pendingExportKeys.contains(exportKey(v))).toList();

  String exportKey(BiliVideo v) => "${v.avid}::${v.cid}";

  // ────────────────────────────────────────────────────────
  // 生命周期
  // ────────────────────────────────────────────────────────

  /// 初始化（Screen 的 initState 调用）
  Future<void> init() async {
    _coverDir = await SettingsService.getCoversDir();
    await loadCachedList();
    // 绑定封面下载进度到 notifyListeners
    BiliCoverService.onProgressChanged = notifyListeners;
  }

  /// 释放（Screen 的 dispose 调用）
  @override
  void dispose() {
    _exportTimer?.cancel();
    BiliCoverService.onProgressChanged = null;
    super.dispose();
  }

  // ────────────────────────────────────────────────────────
  // 数据加载
  // ────────────────────────────────────────────────────────

  /// 从缓存恢复视频列表（同时过滤已不存在的文件）
  Future<void> loadCachedList() async {
    final cache = await VideoCacheService.loadVideoList();
    if (cache != null) {
      final videos = cache["videos"] as List<BiliVideo>;
      if (videos.isNotEmpty) {
        // 过滤：已删除（文件夹不存在）的视频不再恢复
        // 临时目录被清理时也自然过滤——因为 scanDirectory/buildFromShizukuScan
        // 会重新生成完整列表，这里只做兜底校验。
        final valid = <BiliVideo>[];
        int filteredCount = 0;
        for (final v in videos) {
          if (Directory(v.folderPath).existsSync()) {
            valid.add(v);
          } else {
            filteredCount++;
          }
        }
        _videos = valid;
        _rootPath = cache["rootPath"] as String?;
        _shizukuScanMode = cache["isScanMode"] as bool? ?? false;
        _diagnosticInfo = cache["diagnosticInfo"] as String?;
        _loading = false;
        // 如果有被过滤掉的视频 → 缓存已过期，重新保存一次清理后的列表
        if (filteredCount > 0 && valid.isNotEmpty) {
          unawaited(VideoCacheService.saveVideoList(
            videos: valid,
            rootPath: _rootPath!,
            isScanMode: _shizukuScanMode,
            diagnosticInfo: "${_diagnosticInfo ?? ""}\n【缓存修复】过滤 ${filteredCount} 个已不存在的视频",
          ));
        }
        // 触发封面下载
        triggerCoverDownload();
        // 记录诊断日志
        unawaited(DiagnosticLogService.addEntry(
            "缓存恢复: ${_videos.length} 视频${filteredCount > 0 ? " (过滤 ${filteredCount} 个不存在)" : ""}\n${_diagnosticInfo ?? ""}"));
      }
    }
    // 异步刷新已导出状态
    unawaited(refreshExportedKeys());
  }

  /// 刷新已导出状态集合
  Future<void> refreshExportedKeys() async {
    if (_videos.isEmpty) return;
    final keys = await ExportService.getExportedKeys(_videos);

    // 额外扫描用户设置的默认导出路径
    try {
      final defaultPath = await SettingsService.getDefaultExportPath();
      if (defaultPath != null && defaultPath.isNotEmpty) {
        final defaultDir = Directory(defaultPath);
        if (await defaultDir.exists()) {
          final existingFiles = <String>{};
          await for (final f in defaultDir.list()) {
            if (f is File && f.path.endsWith(".mp4")) {
              existingFiles.add(f.path.split(Platform.pathSeparator).last);
            }
          }
          for (final v in _videos) {
            if (existingFiles.contains(v.exportFileName)) {
              keys.add("${v.avid}::${v.title}");
            }
          }
        }
      }
    } catch (_) {}

    _exportedKeys = keys;
    notifyListeners();
  }

  /// 触发封面下载（扫描完成后调用）
  void triggerCoverDownload() {
    if (_coverDir == null || _videos.isEmpty) return;
    BiliCoverService.startDownload(
      videos: _videos,
      coversDir: _coverDir!,
    );
  }

  // ────────────────────────────────────────────────────────
  // 扫描
  // ────────────────────────────────────────────────────────

  /// 扫描目录（非 Shizuku 模式）
  Future<void> scanDirectory(String path) async {
    BiliCoverService.cancel();
    _shizukuScanMode = false;
    _rootPath = path;
    _loading = true;
    _error = null;
    _videos = [];
    notifyListeners();

    final buffer = StringBuffer("路径: $path\n");
    try {
      final diagnostic = ScanDiagnostic();
      final vs = await BiliParser.scanRootDirectory(
        path,
        diagnostic: diagnostic,
      );
      buffer.write("诊断: ${diagnostic.summary}\n视频数: ${vs.length}\n");
      _videos = vs;
      _loading = false;
      _diagnosticInfo = buffer.toString();
      if (vs.isEmpty) _error = "没有找到视频";
      notifyListeners();

      // 保存缓存
      VideoCacheService.saveVideoList(
        videos: vs,
        rootPath: path,
        isScanMode: false,
        diagnosticInfo: buffer.toString(),
      );

      // 触发封面下载 + 刷新导出状态 + 诊断日志
      triggerCoverDownload();
      unawaited(refreshExportedKeys());
      unawaited(DiagnosticLogService.addEntry(
          "目录扫描完成: ${vs.length} 个视频\n$buffer"));
    } catch (e) {
      buffer.write("异常: $e\n");
      _loading = false;
      _diagnosticInfo = buffer.toString();
      _error = "扫描出错: $e";
      notifyListeners();
    }
  }

  /// 从 Shizuku 仅扫描结果构建视频列表
  Future<void> buildFromShizukuScan(
    List<ShizukuScanResult> scanResults,
    String tempPath,
    String scanDiag,
  ) async {
    BiliCoverService.cancel();
    _shizukuScanMode = true;
    _rootPath = tempPath;

    final buildResult =
        BiliParser.buildFromShizukuScan(scanResults, tempPath);
    final newVideos = List<BiliVideo>.from(buildResult["videos"] ?? []);
    _videos = newVideos;
    _loading = false;
    _error = null;
    _diagnosticInfo = "$scanDiag\n${buildResult["diagnostic"]}";
    if (_videos.isEmpty) _error = "没有找到视频";
    notifyListeners();

    // 保存缓存
    VideoCacheService.saveVideoList(
      videos: newVideos,
      rootPath: tempPath,
      isScanMode: true,
      diagnosticInfo: _diagnosticInfo ?? "",
    );

    // 触发封面下载 + 刷新导出状态
    triggerCoverDownload();
    unawaited(refreshExportedKeys());
    unawaited(DiagnosticLogService.addEntry(
        "Shizuku 扫描完成: ${newVideos.length} 个视频\n$scanDiag\n${buildResult["diagnostic"]}"));
  }

  // ────────────────────────────────────────────────────────
  // 排序
  // ────────────────────────────────────────────────────────

  void toggleSort(SortField field) {
    if (_sortField == field) {
      _sortOrder =
          _sortOrder == SortOrder.asc ? SortOrder.desc : SortOrder.asc;
    } else {
      _sortField = field;
      _sortOrder = SortOrder.desc;
    }
    notifyListeners();
  }

  SortField get sortField => _sortField;
  SortOrder get sortOrder => _sortOrder;

  // ────────────────────────────────────────────────────────
  // 选择模式
  // ────────────────────────────────────────────────────────

  void enterSelectMode([int? startIndex]) {
    _selectMode = true;
    if (startIndex != null) _selected.add(startIndex);
    notifyListeners();
  }

  void exitSelectMode() {
    _selectMode = false;
    _selected.clear();
    notifyListeners();
  }

  void toggleSelect(int index) {
    if (_selected.contains(index)) {
      _selected.remove(index);
    } else {
      _selected.add(index);
    }
    if (_selected.isEmpty) _selectMode = false;
    notifyListeners();
  }

  bool isSelected(int index) => _selected.contains(index);

  // ────────────────────────────────────────────────────────
  // 待导出队列
  // ────────────────────────────────────────────────────────

  /// 获取同一 avid 的所有视频（分P视频组）
  List<BiliVideo> getSiblingVideos(BiliVideo video) {
    return _videos.where((v) => v.avid == video.avid).toList();
  }

  void togglePendingExport(BiliVideo v) {
    final siblings = getSiblingVideos(v);
    if (siblings.length > 1) {
      // 分P视频：任一在队列中则全部移出，否则全部加入
      final anyPending = siblings.any((s) => _pendingExportKeys.contains(exportKey(s)));
      for (final s in siblings) {
        if (anyPending) {
          _pendingExportKeys.remove(exportKey(s));
        } else {
          _pendingExportKeys.add(exportKey(s));
        }
      }
    } else {
      // 单视频：正常切换
      final key = exportKey(v);
      if (_pendingExportKeys.contains(key)) {
        _pendingExportKeys.remove(key);
      } else {
        _pendingExportKeys.add(key);
      }
    }
    notifyListeners();
  }

  bool isPendingExport(BiliVideo v) =>
      _pendingExportKeys.contains(exportKey(v));

  void clearPendingExports() {
    _pendingExportKeys.clear();
    notifyListeners();
  }

  // ────────────────────────────────────────────────────────
  // 导出流程（纯逻辑，无对话框）
  // ────────────────────────────────────────────────────────

  /// 执行导出（Screen 负责展示进度对话框并监听 exportProgress）
  /// 返回导出结果列表。调用前确保 [list] 和 [customDir] 已在 Screen 中确定。
  Future<List<ExportResult>> executeExport(
    List<BiliVideo> list, {
    String? customDir,
  }) async {
    if (_exporting) return [];
    _exporting = true;
    exportCancelled = false;
    _exportErrors.clear();
    _exportStopwatch = Stopwatch()..start();

    final results = <ExportResult>[];
    int done = 0;
    int skipped = 0;
    final total = list.length;

    exportProgress.value = ExportProgress(
      done: 0,
      total: total,
      currentFileName: "准备中...",
    );

    // 每秒刷新进度中的计时
    _exportTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      exportProgress.value = exportProgress.value.copyWith(
        elapsed: _exportStopwatch.elapsed,
      );
    });

    for (int i = 0; i < list.length && !exportCancelled; i++) {
      final v = list[i];
      exportProgress.value = ExportProgress(
        done: done,
        total: total,
        skippedCount: skipped,
        currentFileName: "${v.title} (${v.ownerName})",
        elapsed: _exportStopwatch.elapsed,
      );

      ExportResult r;
      String? errorDetail;
      try {
        r = await ExportService.exportVideo(v, customDir: customDir);
        if (!r.success) {
          errorDetail = r.error ?? "未知错误";
        }
      } catch (e) {
        errorDetail = "$e";
        r = ExportResult(false, error: "$e");
      }
      results.add(r);

      if (errorDetail != null) {
        _exportErrors.add("${v.title} (${v.ownerName}): $errorDetail");
        unawaited(DiagnosticLogService.addEntry(
            "[导出失败] ${v.title} (${v.avid})\n"
            "  UP主: ${v.ownerName}\n"
            "  路径: ${v.folderPath}\n"
            "  错误: $errorDetail"));
      }

      if (r.success) {
        if (r.skipped) skipped++;
        done++;
      }
    }

    _exportTimer?.cancel();
    _exportTimer = null;
    _exportStopwatch.stop();
    _exporting = false;

    exportProgress.value = ExportProgress(
      done: done,
      total: total,
      skippedCount: skipped,
      currentFileName: "",
      elapsed: _exportStopwatch.elapsed,
    );

    // 刷新导出状态
    unawaited(refreshExportedKeys());

    return results;
  }

  /// 导出完成后删除原始缓存文件夹
  Future<void> deleteOriginalsAfterExport(List<BiliVideo> list) async {
    await ExportService.deleteOriginal(list);
    _videos.removeWhere((v) => list.contains(v));
    notifyListeners();
  }

  /// Snackbar
  void showSnack(String msg) {
    snackMessage.value = msg;
  }

  // ── 删除 ────────────────────────────────────────────────────────

  /// 删除单个视频的源文件夹（通过 DeleteService）
  ///
  /// 返回 [DeleteResult]，Screen 可根据结果弹 SnackBar。
  Future<DeleteResult> deleteSingle(BiliVideo video) async {
    final result = await DeleteService.deleteSourceFolder(video);
    if (result.success) {
      _videos.removeWhere(
          (v) => v.avid == video.avid && v.title == video.title);
      notifyListeners();
      await saveCache();
    }
    return result;
  }

  /// 删除选中的视频文件夹（通过 DeleteService）
  ///
  /// 返回 [DeleteResult] 列表，Screen 可根据结果展示汇总。
  Future<List<DeleteResult>> deleteSelected() async {
    final list = selectedVideos;
    if (list.isEmpty) return [];
    final results = await DeleteService.deleteBatch(list);
    final succeeded = <BiliVideo>[];
    for (int i = 0; i < list.length; i++) {
      if (results[i].success) succeeded.add(list[i]);
    }
    _videos.removeWhere((v) => succeeded.contains(v));
    exitSelectMode();
    notifyListeners();
    await saveCache();
    return results;
  }

  /// 批量删除指定的视频文件夹（供外部调用，通过 DeleteService）
  Future<List<DeleteResult>> deleteFolders(List<BiliVideo> list) async {
    final results = await DeleteService.deleteBatch(list);
    final succeeded = <BiliVideo>[];
    for (int i = 0; i < list.length; i++) {
      if (results[i].success) succeeded.add(list[i]);
    }
    _videos.removeWhere((v) => succeeded.contains(v));
    notifyListeners();
    await saveCache();
    return results;
  }

  // ────────────────────────────────────────────────────────
  // 播放
  // ────────────────────────────────────────────────────────

  /// 准备播放视频文件，返回可播放的文件路径
  /// scan-only 模式会通过 Shizuku 复制到临时目录
  Future<String?> preparePlay(BiliVideo v) async {
    if (v.isScanOnly && v.originalMediaPath != null) {
      final cacheDir = await getTemporaryDirectory();
      final playDir = "${cacheDir.path}/bili_play_${v.cid}";
      final ok = await ShellCopyService.copyForExportViaShizuku(
        originalMediaPath: v.originalMediaPath!,
        destMediaPath: playDir,
      );
      if (!ok) return null;
      final playFile = File("$playDir/video.m4s");
      if (await playFile.exists()) return playFile.path;
      return null;
    }

    // 非 scan-only
    final src = File(v.videoPath);
    if (!await src.exists()) return null;

    final cacheDir = await getTemporaryDirectory();
    final playFile = File("${cacheDir.path}/bili_play_${v.cid}.m4s");
    try {
      await src.copy(playFile.path);
      return playFile.path;
    } catch (_) {
      // 复制失败，尝试直接返回原始路径
      if (await src.exists()) return v.videoPath;
      return null;
    }
  }

  /// 获取合并后的视频路径（用于直接播放已合并文件）
  Future<String?> getMergedPath(BiliVideo v) async {
    if (v.mergeOutputPath != null && File(v.mergeOutputPath!).existsSync()) {
      return v.mergeOutputPath;
    }
    return null;
  }

  // ────────────────────────────────────────────────────────
  // 缓存管理
  // ────────────────────────────────────────────────────────

  /// 清空所有视频列表和状态（设置页清空缓存时调用）
  void clearVideos() {
    _videos = [];
    _rootPath = null;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  /// 保存当前视频列表到缓存（删除后调用，避免重启后恢复已删文件）
  ///
  /// 添加 try-catch 防止静默失败，删除操作应确保缓存同步写入后才返回。
  Future<void> saveCache() async {
    if (_rootPath == null) return;
    try {
      await VideoCacheService.saveVideoList(
        videos: List.from(_videos),
        rootPath: _rootPath!,
        isScanMode: _shizukuScanMode,
        diagnosticInfo: _diagnosticInfo ?? "",
      );
    } catch (e) {
      unawaited(DiagnosticLogService.addEntry(
          "[缓存写入失败] saveCache: $e\n"
          "  rootPath: $_rootPath\n"
          "  视频数: ${_videos.length}"));
    }
  }

  /// 清除临时文件
  Future<bool> cleanTempFiles() async {
    final tempPath = await ShellCopyService.getTempPath();
    final fullPath = await ShellCopyService.getFullCopyPath();
    final hasTemp = await Directory(tempPath).exists();
    final hasFull = await Directory(fullPath).exists();
    if (!hasTemp && !hasFull) return false;
    await ShellCopyService.cleanTemp();
    await ShellCopyService.cleanFullCopyTemp();
    return true;
  }

  /// 判断是否有临时缓存
  Future<bool> hasTempFiles() async {
    final tempPath = await ShellCopyService.getTempPath();
    final fullPath = await ShellCopyService.getFullCopyPath();
    return await Directory(tempPath).exists() ||
        await Directory(fullPath).exists();
  }

  // ────────────────────────────────────────────────────────
  // 崩溃恢复
  // ────────────────────────────────────────────────────────

  /// 检查是否有未完成的导出
  Future<ExportQueueState?> checkIncompleteState() async {
    return ExportQueueService.getIncompleteState();
  }

  /// 恢复导出队列
  Future<void> resumeExportQueue() async {
    await ExportQueueService.discardCurrentAndResume();
  }

  /// 清除崩溃状态
  Future<void> clearCrashState() async {
    await ExportQueueService.clearState();
  }

  // ────────────────────────────────────────────────────────
  // 内部/工具
  // ────────────────────────────────────────────────────────

  /// 获取导出错误列表
  List<String> get exportErrors => List.unmodifiable(_exportErrors);

  /// 获取导出成功数（executeExport 后查询）
  int get exportDoneCount => exportProgress.value.done;
}
