import "dart:async";
import "dart:convert";
import "dart:io";
import "package:path_provider/path_provider.dart";
import "package:open_file/open_file.dart";
import "../models/bili_video.dart";
import "../models/export_record.dart";
import "diagnostic_log_service.dart";
import "ffmpeg_merge_service.dart";
import "shell_copy_service.dart";
import "settings_service.dart";

/// Export business logic: merge + copy to target directory + record history
///
/// Supports export dedup: skips automatically when target file already exists.
class ExportService {
  static List<ExportRecord> _history = [];
  static bool _loaded = false;

  /// Exported file unique key set ({avid}::{title}), for fast lookup
  static Set<String> _exportedKeys = {};

  /// Get default export directory (fixed at /Download/Bilimerge)
  static Future<String> getExportDirectory() async {
    final out = Directory("/storage/emulated/0/Download/Bilimerge");
    if (!await out.exists()) await out.create(recursive: true);
    return out.path;
  }

  /// 检查导出路径是否合法（FFmpeg native 进程无法写入含 # 前缀目录的路径）
  static String? _validateExportPath(String path) {
    final segments = path.split(Platform.pathSeparator);
    for (final seg in segments) {
      if (seg.startsWith("#")) {
        return "导出路径包含非法字符 #：${seg}\n请选择其他目录";
      }
    }
    return null;
  }

  /// Export single video: check dedup -> merge -> copy -> record history
  ///
  /// If target file already exists, skip merge and return skipped=true.
  static Future<ExportResult> exportVideo(BiliVideo video, {String? customDir}) async {
    final outDir = customDir ?? await getExportDirectory();
    final outputPath = "$outDir/${video.exportFileName}";

    // Path validation: FFmpeg native process cannot write to paths with # prefix
    if (customDir != null) {
      final pathError = _validateExportPath(customDir);
      if (pathError != null) {
        return ExportResult(false, error: pathError);
      }
    }

    // Dedup check: target file exists -> skip
    if (File(outputPath).existsSync()) {
      final f = File(outputPath);
      final size = await f.length();
      final record = ExportRecord(
        fileName: video.exportFileName,
        filePath: outputPath,
        originalFolderPath: video.folderPath,
        fileSize: size,
        exportTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: video.title,
        ownerName: video.ownerName,
        avid: video.avid,
      );
      return ExportResult(true, outputPath: outputPath, record: record, skipped: true);
    }

    // If already merged, copy directly
    if (video.mergeOutputPath != null && File(video.mergeOutputPath!).existsSync()) {
      await File(video.mergeOutputPath!).copy(outputPath);
    } else {
      String videoPath = video.videoPath;
      String audioPath = video.audioPath;

      // Scan-only mode: copy m4s via Shizuku to temp dir
      if (video.isScanOnly && video.originalMediaPath != null) {
        final tempDir = await getTemporaryDirectory();
        final tempMediaDir = "${tempDir.path}/bili_export_${video.cid}";
        final ok = await ShellCopyService.copyForExportViaShizuku(
          originalMediaPath: video.originalMediaPath!,
          destMediaPath: tempMediaDir,
        );
        if (!ok) {
          unawaited(DiagnosticLogService.addEntry(
              "[导出失败] ${video.title}: Shizuku 复制失败\n"
              "  源: ${video.originalMediaPath}"));
          return ExportResult(false, error: "Cannot copy video files via Shizuku");
        }
        videoPath = "$tempMediaDir/video.m4s";
        audioPath = "$tempMediaDir/audio.m4s";

        final result = await FfmpegMergeService.mergeVideo(
          videoPath: videoPath,
          audioPath: audioPath,
          outputPath: outputPath,
        );
        try { Directory(tempMediaDir).deleteSync(recursive: true); } catch (_) {}
        if (!result.success) {
          unawaited(DiagnosticLogService.addEntry(
              "[导出失败] ${video.title}: 合并失败 (scan-only)\n"
              "  错误: ${result.errorMessage}"));
          unawaited(DiagnosticLogService.addEntry(
              "[导出失败] FFmpeg stderr:\n${result.stderr}"));
          return ExportResult(false, error: result.errorMessage);
        }
        // 成功合并，记录耗时
        unawaited(DiagnosticLogService.addEntry(
            "[合并耗时] ${video.title} (scan-only, FFmpeg)\n"
            "  ${result.timingSummary}"));
      } else {
        // Normal mode: files already local
        // 检查源文件是否存在
        if (!File(video.videoPath).existsSync()) {
          unawaited(DiagnosticLogService.addEntry(
              "[导出失败] ${video.title}: 视频文件不存在\n"
              "  路径: ${video.videoPath}"));
          return ExportResult(false, error: "视频文件不存在");
        }
        if (!File(video.audioPath).existsSync()) {
          unawaited(DiagnosticLogService.addEntry(
              "[导出失败] ${video.title}: 音频文件不存在\n"
              "  路径: ${video.audioPath}"));
          return ExportResult(false, error: "音频文件不存在");
        }
        final result = await FfmpegMergeService.mergeVideo(
          videoPath: videoPath,
          audioPath: audioPath,
          outputPath: outputPath,
        );
        if (!result.success) {
          unawaited(DiagnosticLogService.addEntry(
              "[导出失败] ${video.title}: 合并失败\n"
              "  视频: ${video.videoPath}\n"
              "  音频: ${video.audioPath}\n"
              "  错误: ${result.errorMessage}"));
          unawaited(DiagnosticLogService.addEntry(
              "[导出失败] FFmpeg stderr:\n${result.stderr}"));
          return ExportResult(false, error: result.errorMessage);
        }
        // 成功合并，记录耗时
        unawaited(DiagnosticLogService.addEntry(
            "[合并耗时] ${video.title} (FFmpeg)\n"
            "  ${result.timingSummary}"));
      }
    }

    final f = File(outputPath);
    final size = await f.length();

    final record = ExportRecord(
      fileName: video.exportFileName,
      filePath: outputPath,
      originalFolderPath: video.folderPath,
      fileSize: size,
      exportTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: video.title,
      ownerName: video.ownerName,
      avid: video.avid,
    );
    _history.insert(0, record);
    _exportedKeys.add(_exportKey(video));
    await _saveHistory();

    return ExportResult(true, outputPath: outputPath, record: record);
  }

  /// Batch export
  ///
  /// Each video processed independently, existing ones auto-skipped.
  static Future<List<ExportResult>> exportBatch(List<BiliVideo> videos, {String? customDir}) async {
    final results = <ExportResult>[];
    for (final v in videos) {
      final r = await exportVideo(v, customDir: customDir);
      results.add(r);
    }
    return results;
  }

  /// Check if video has been exported to default directory
  static Future<bool> isExported(BiliVideo video) async {
    final key = _exportKey(video);
    if (_exportedKeys.contains(key)) return true;

    // Check disk
    final outDir = await getExportDirectory();
    final target = File("$outDir/${video.exportFileName}");
    if (await target.exists()) {
      _exportedKeys.add(key);
      return true;
    }
    // Also check user-set default export path
    final customDefault = await _getDefaultExportPath();
    if (customDefault != null) {
      final customTarget = File("$customDefault/${video.exportFileName}");
      if (await customTarget.exists()) {
        _exportedKeys.add(key);
        return true;
      }
    }
    return false;
  }

  /// Batch check export status, returns Set of exported keys
  static Future<Set<String>> getExportedKeys(List<BiliVideo> videos) async {
    final keys = <String>{};
    if (!_loaded) await _loadHistory();
    keys.addAll(_exportedKeys);

    // Check default directory for files
    final outDir = await getExportDirectory();
    final outFiles = <String>{};
    if (await Directory(outDir).exists()) {
      await for (final f in Directory(outDir).list()) {
        if (f is File && f.path.endsWith('.mp4')) {
          outFiles.add(f.path.split(Platform.pathSeparator).last);
        }
      }
    }

    // Check custom default path
    final customDefault = await _getDefaultExportPath();
    if (customDefault != null && await Directory(customDefault).exists()) {
      await for (final f in Directory(customDefault).list()) {
        if (f is File && f.path.endsWith('.mp4')) {
          outFiles.add(f.path.split(Platform.pathSeparator).last);
        }
      }
    }

    for (final v in videos) {
      if (outFiles.contains(v.exportFileName)) {
        keys.add(_exportKey(v));
      }
    }

    return keys;
  }

  static String _exportKey(BiliVideo v) => "${v.avid}::${v.title}";

  static Future<String?> _getDefaultExportPath() async {
    try {
      return await SettingsService.getDefaultExportPath();
    } catch (_) {
      return null;
    }
  }

  static Future<void> playVideo(BiliVideo video) async {
    String? path;
    if (video.mergeOutputPath != null && File(video.mergeOutputPath!).existsSync()) {
      path = video.mergeOutputPath;
    } else {
      final outDir = await getExportDirectory();
      path = "$outDir/${video.exportFileName}";
      if (!File(path!).existsSync()) {
        final r = await FfmpegMergeService.mergeVideo(
          videoPath: video.videoPath,
          audioPath: video.audioPath,
          outputPath: path!,
        );
        if (!r.success) return;
      }
    }
    OpenFile.open(path!);
  }

  static Future<bool> deleteOriginal(List<BiliVideo> videos) async {
    try {
      for (final v in videos) {
        final dir = Directory(v.folderPath);
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<ExportRecord>> getHistory() async {
    if (!_loaded) await _loadHistory();
    return List.unmodifiable(_history);
  }

  static Future<void> markOriginalDeleted(ExportRecord record) async {
    final idx = _history.indexWhere((r) => r.filePath == record.filePath);
    if (idx >= 0) {
      _history[idx] = ExportRecord(
        fileName: record.fileName,
        filePath: record.filePath,
        originalFolderPath: record.originalFolderPath,
        fileSize: record.fileSize,
        exportTimestamp: record.exportTimestamp,
        title: record.title,
        ownerName: record.ownerName,
        avid: record.avid,
        originalDeleted: true,
      );
      await _saveHistory();
    }
  }

  static Future<void> clearHistory() async {
    _history.clear();
    await _saveHistory();
  }

  static Future<void> _loadHistory() async {
    _loaded = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File("${dir.path}/BiliExportHistory.json");
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _history = list.map((e) => ExportRecord.fromJson(e as Map<String, dynamic>)).toList();
        // 从历史记录预填充 _exportedKeys（快速判断已导出）
        for (final r in _history) {
          _exportedKeys.add("${r.avid}::${r.title}");
        }
      }
    } catch (_) { _history = []; }
  }

  static Future<void> _saveHistory() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File("${dir.path}/BiliExportHistory.json");
    await f.writeAsString(jsonEncode(_history.map((e) => e.toJson()).toList()));
  }
}

class ExportResult {
  final bool success;
  final String? error;
  final String? outputPath;
  final ExportRecord? record;
  final bool skipped; // true when file already existed, no work done
  ExportResult(this.success, {this.error, this.outputPath, this.record, this.skipped = false});
}
