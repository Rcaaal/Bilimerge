/// 删除服务 — 先标记兜底，再静默尝试直接删除
///
/// ## 策略
/// 1. 在 avid 文件夹下创建标记文件 `!{avid}.del`（主流程，确保可追踪）
/// 2. 标记成功后后台静默尝试直接删除（4 种策略，失败不影响标记文件）
///
/// ## 标记文件格式
/// 文件名: `!{avid}.del`
/// 内容:  `UP主名 | 视频标题 | AV号/BV号`
///
/// ## 安全
///   - APK 检测：拦截路径含 .apk 的文件夹
///   - 操作日志：每次操作记录到诊断日志
import "dart:async";
import "dart:convert";
import "dart:io";

import "../models/bili_video.dart";
import "../models/delete_result.dart";
import "diagnostic_log_service.dart";
import "shell_copy_service.dart";

/// 文件夹信息（用于删除确认对话框展示）
class FolderInfo {
  final String path;
  final int fileCount;
  final int totalBytes;
  final bool containsApk;

  const FolderInfo({
    required this.path,
    this.fileCount = 0,
    this.totalBytes = 0,
    this.containsApk = false,
  });

  String get sizeFormatted {
    if (totalBytes <= 0) return "未知";
    if (totalBytes < 1024 * 1024) return "${(totalBytes / 1024).toStringAsFixed(1)} KB";
    return "${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB";
  }

  String get summary => "文件: $fileCount 个 · 共 $sizeFormatted";
}

class DeleteService {
  // ── APK 检测 ──────────────────────────────────────────

  static bool _containsApk(String path) =>
      path.contains(".apk") || path.contains(".APK") || path.contains(".apk/");

  // ── 路径映射 ──────────────────────────────────────────

  /// 解析 avid 文件夹路径
  static Future<String> _resolveTargetPath(BiliVideo video) async {
    final avidName = video.avidFolderName;

    String? locate(String path) {
      if (path.isEmpty || avidName.isEmpty) return null;
      final pattern = '/$avidName/';
      final idx = path.indexOf(pattern);
      if (idx >= 0) return path.substring(0, idx) + pattern;
      if (path.endsWith('/$avidName') || path.endsWith('/$avidName/')) {
        final i = path.lastIndexOf('/$avidName');
        return path.substring(0, i) + '/$avidName/';
      }
      return null;
    }

    if (video.originalMediaPath != null && video.originalMediaPath!.isNotEmpty) {
      final found = locate(video.originalMediaPath!);
      if (found != null) return found;
      final pdir = _parentDir(video.originalMediaPath!);
      if (pdir.isNotEmpty && _isInAndroidData(pdir)) return pdir;
    }

    // 全量复制模式：originalSourceFolder 存的是 Android/data 下的 avid 目录路径
    if (video.originalSourceFolder != null && video.originalSourceFolder!.isNotEmpty) {
      if (_isInAndroidData(video.originalSourceFolder!)) {
        final found = locate(video.originalSourceFolder!);
        if (found != null) return found;
        return video.originalSourceFolder!;
      }
    }

    final vpath = video.videoPath;
    if (vpath.isNotEmpty) {
      if (_isInAndroidData(vpath)) {
        final found = locate(vpath);
        if (found != null) return found;
      }
      if (_isInTempDir(vpath)) {
        final origin = await _resolveOriginFromIndex(vpath);
        if (origin != null) return origin;
        final found = locate(vpath);
        if (found != null) return found;
      }
    }

    if (avidName.isNotEmpty && video.folderPath.isNotEmpty) {
      final found = locate(video.folderPath);
      if (found != null) return found;
    }
    return "";
  }

  static Future<String?> _resolveOriginFromIndex(String tempPath) async {
    try {
      String? cacheRoot;
      if (tempPath.contains("BiliFullCopyCache")) {
        cacheRoot = await ShellCopyService.getFullCopyPath();
      } else if (tempPath.contains("BiliTempCache")) {
        cacheRoot = await ShellCopyService.getTempPath();
      }
      if (cacheRoot == null) return null;
      final indexFile = File('$cacheRoot/.origin_index.json');
      if (!indexFile.existsSync()) return null;
      final data = jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
      final avidName = tempPath.split('/').where((s) => s.isNotEmpty).last;
      if (data.containsKey(avidName)) return data[avidName].toString();
    } catch (_) {}
    return null;
  }

  static bool _isInTempDir(String path) =>
      path.contains("BiliTempCache") || path.contains("BiliFullCopyCache") ||
      path.contains("bili_export_") || path.contains("bili_play_");

  static bool _isInAndroidData(String path) =>
      path.contains("/Android/data/") || path.contains("/android/data/");

  // ── 获取文件夹信息 ──────────────────────────────────

  static Future<FolderInfo> getFolderInfo(BiliVideo video) async {
    final path = await _resolveTargetPath(video);
    if (path.isEmpty) return const FolderInfo(path: "");

    if (_isInAndroidData(path) || video.isScanOnly) {
      if (!await _canUseShizuku()) {
        return FolderInfo(path: path, containsApk: _containsApk(path));
      }
      final countResult = await ShellCopyService.executeShellViaShizuku(
        "find '$path' -type f 2>/dev/null | wc -l");
      final fileCount = int.tryParse((countResult['stdout'] as String?)?.trim() ?? "0") ?? 0;
      final sizeResult = await ShellCopyService.executeShellViaShizuku(
        "du -sb '$path' 2>/dev/null | cut -f1");
      final totalBytes = int.tryParse((sizeResult['stdout'] as String?)?.trim() ?? "0") ?? 0;
      return FolderInfo(path: path, fileCount: fileCount, totalBytes: totalBytes, containsApk: _containsApk(path));
    }

    final dir = Directory(path);
    if (!await dir.exists()) return FolderInfo(path: path, containsApk: _containsApk(path));
    try {
      int count = 0, size = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) { count++; try { size += await entity.length(); } catch (_) {} }
      }
      return FolderInfo(path: path, fileCount: count, totalBytes: size, containsApk: _containsApk(path));
    } catch (_) {
      return FolderInfo(path: path, containsApk: _containsApk(path));
    }
  }

  // ── 标记删除 ────────────────────────────────────────

  /// 生成标记文件内容: `UP主名 | 视频标题 | AV号/BV号`
  static String _markerContent(BiliVideo video) {
    final avidTrim = video.avid.trim();
    final bvidTrim = video.bvid.trim();
    String idStr;
    if (avidTrim.isNotEmpty && int.tryParse(avidTrim) != null) {
      idStr = "AV$avidTrim";
    } else if (bvidTrim.isNotEmpty) {
      idStr = bvidTrim.startsWith("BV") ? bvidTrim : "BV$bvidTrim";
    } else {
      idStr = "";
    }
    final parts = [video.ownerName, video.title];
    if (idStr.isNotEmpty) parts.add(idStr);
    return parts.join(" | ");
  }

  /// 确保遍历删除脚本存在于 /Download/Bilimerge/ 目录
  static Future<void> _ensureDeletionScript() async {
    final scriptDir = "/storage/emulated/0/Download/Bilimerge";
    try {
      await Directory(scriptDir).create(recursive: true);
    } catch (_) {
      await ShellCopyService.executeShellViaShizuku("mkdir -p '$scriptDir' 2>/dev/null");
    }

    final scriptPath = "$scriptDir/delete_marked.sh";
    try {
      if (await File(scriptPath).exists()) return;
    } catch (_) {}

    final downloadDir = "/storage/emulated/0/Android/data/tv.danmaku.bili/download";
    final logFile = "$scriptDir/deleted_records.txt";

    final script = r'''#!/system/bin/sh
# ============================================
# BiliMerge 删除标记执行脚本
# 由 BiliMerge App 自动生成
# ============================================
DOWNLOAD_DIR="__DIR__"
LOG_FILE="__LOG__"
MARKER_PATTERN="!*.del"

echo "========================================"
echo " BiliMerge 删除标记执行脚本"
echo "========================================"
echo "扫描目录: $DOWNLOAD_DIR"
echo "日志文件: $LOG_FILE"
echo ""

count=0
find "$DOWNLOAD_DIR" -name "$MARKER_PATTERN" -type f 2>/dev/null | while IFS= read -r marker; do
    content=$(cat "$marker" 2>/dev/null)
    [ -z "$content" ] && continue
    avid_dir=$(dirname "$marker")
    if [ -d "$avid_dir" ]; then
        echo "[$((count+1))] 发现标记: $avid_dir"
        echo "    内容: $content"
        rm -rf "$avid_dir" 2>/dev/null
        if [ ! -d "$avid_dir" ]; then
            echo "    OK 已删除"
            echo "$(date) | 已删除 | $content" >> "$LOG_FILE"
            count=$((count + 1))
        else
            echo "    FAIL 删除失败"
        fi
    fi
done

echo ""
echo "完成! 共处理 $count 个标记"
echo ""
echo "提示：如果上方未找到任何标记，"
echo "也可以用 MT 管理器的文件浏览器手动删除 avid 文件夹"
''';

    final finalScript = script
        .replaceAll("__DIR__", downloadDir)
        .replaceAll("__LOG__", logFile);

    try {
      await File(scriptPath).writeAsString(finalScript);
    } catch (_) {
      await ShellCopyService.writeTextFileViaShizuku(filePath: scriptPath, content: finalScript);
    }
  }

  /// 删除视频缓存文件夹
  ///
  /// 1. 先尝试直接删除（4种策略：SAF / content shell / rm / mv）
  /// 2. 直接删除成功 → 返回 success: true（不创建标记文件）
  /// 3. 直接删除失败 → 创建 `!{avid}.del` 标记文件兜底
  static Future<DeleteResult> markForDeletion(BiliVideo video) async {
    final folderPath = await _resolveTargetPath(video);
    if (folderPath.isEmpty) {
      // 路径解析失败但文件夹可能已被手动删除 → 仍视为成功
      return DeleteResult(success: true, path: "", videoTitle: video.title, deletedFileCount: 1);
    }
    if (_containsApk(folderPath)) {
      return DeleteResult(success: false, path: folderPath, videoTitle: video.title, errorMessage: "路径包含 APK");
    }

    // ─── 阶段 1：先尝试直接删除 ───
    if (_isInAndroidData(folderPath)) {
      final delResult = await ShellCopyService.deleteViaSaf(folderPath);
      if (delResult['success'] == true) {
        final method = delResult['method'] as String? ?? '?';
        unawaited(DiagnosticLogService.addEntry(
            "[删除成功] ${video.title} (${video.avid})\n"
            "  UP主: ${video.ownerName}\n"
            "  路径: $folderPath\n"
            "  方法: $method"));
        return DeleteResult(
          success: true,
          path: folderPath,
          videoTitle: video.title,
          deletedFileCount: 1,
          freedBytes: video.totalBytes,
        );
      }
    }

    // ─── 阶段 2：直接删除失败 → 创建标记文件兜底 ───
    final markerFile = "!${video.avidFolderName}.del";
    final basePath = folderPath.endsWith('/') ? folderPath : '$folderPath/';
    final markerPath = "$basePath$markerFile";
    final markerContent = _markerContent(video);

    bool created = false;
    if (_isInAndroidData(folderPath)) {
      created = await ShellCopyService.writeTextFileViaShizuku(filePath: markerPath, content: markerContent);
      if (created) {
        final verify = await ShellCopyService.executeShellViaShizuku(
          "test -f '$markerPath' && echo exists || echo not_found",
        );
        if ((verify['stdout'] as String?)?.trim() != "exists") created = false;
      }
    } else {
      try {
        final dir = Directory(basePath);
        if (!await dir.exists()) await dir.create(recursive: true);
        await File(markerPath).writeAsString(markerContent);
        created = true;
      } catch (_) {
        created = await ShellCopyService.writeTextFileViaShizuku(filePath: markerPath, content: markerContent);
      }
    }

    if (created) {
      unawaited(DiagnosticLogService.addEntry(
          "[标记删除] ${video.title} (${video.avid})\n"
          "  UP主: ${video.ownerName}\n"
          "  路径: $basePath\n"
          "  标记文件: $markerFile\n"
          "  标记内容: $markerContent"));
      unawaited(_ensureDeletionScript());
      return DeleteResult(success: true, path: markerPath, videoTitle: video.title, deletedFileCount: 1);
    }

    unawaited(DiagnosticLogService.addEntry(
        "[标记失败] ${video.title} (${video.avid})\n"
        "  路径: $basePath\n"
        "  标记文件: $markerFile\n"
        "  原因: Shizuku 无法写入标记文件"));
    return DeleteResult(success: false, path: folderPath, videoTitle: video.title,
        errorMessage: "无法写入标记文件，需 Shizuku 授权");
  }

  /// 批量标记删除
  static Future<List<DeleteResult>> markBatchForDeletion(List<BiliVideo> videos) async {
    final results = <DeleteResult>[];
    for (final v in videos) {
      results.add(await markForDeletion(v));
    }
    return results;
  }

  /// 通过路径删除（导出历史用）
  ///
  /// 1. 先尝试直接删除
  /// 2. 成功 → 直接返回成功
  /// 3. 失败 → 创建标记文件兜底
  static Future<DeleteResult> deleteByPath({required String path, String title = ""}) async {
    if (path.isEmpty) {
      return DeleteResult(success: false, path: path, videoTitle: title, errorMessage: "路径为空");
    }

    // ─── 阶段 1：先尝试直接删除 ───
    if (_isInAndroidData(path)) {
      final delResult = await ShellCopyService.deleteViaSaf(path);
      if (delResult['success'] == true) {
        unawaited(DiagnosticLogService.addEntry(
            "[删除成功] $title\n  路径: $path"));
        return DeleteResult(success: true, path: path, videoTitle: title, deletedFileCount: 1);
      }
    }

    // ─── 阶段 2：直接删除失败 → 标记文件兜底 ───
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    final avidName = parts.isNotEmpty ? parts.last : "unknown";
    final basePath = path.endsWith('/') ? path : '$path/';
    final markerPath = "${basePath}!$avidName.del";

    bool created = false;
    if (_isInAndroidData(path)) {
      created = await ShellCopyService.writeTextFileViaShizuku(filePath: markerPath, content: title);
      if (created) {
        final verify = await ShellCopyService.executeShellViaShizuku(
          "test -f '$markerPath' && echo exists || echo not_found",
        );
        if ((verify['stdout'] as String?)?.trim() != "exists") created = false;
      }
    } else {
      try {
        final dir = Directory(basePath);
        if (!await dir.exists()) await dir.create(recursive: true);
        await File(markerPath).writeAsString(title);
        created = true;
      } catch (_) {
        created = await ShellCopyService.writeTextFileViaShizuku(filePath: markerPath, content: title);
      }
    }

    if (created) {
      unawaited(DiagnosticLogService.addEntry(
          "[标记删除] $title\n  路径: $path\n  标记文件: !$avidName.del"));
      unawaited(_ensureDeletionScript());
      return DeleteResult(success: true, path: markerPath, videoTitle: title, deletedFileCount: 1);
    }
    return DeleteResult(success: false, path: path, videoTitle: title, errorMessage: "无法写入标记文件");
  }

  // ── 旧接口兼容 ──────────────────────────────────────

  static Future<DeleteResult> deleteSourceFolder(BiliVideo video) => markForDeletion(video);
  static Future<List<DeleteResult>> deleteBatch(List<BiliVideo> videos) => markBatchForDeletion(videos);

  // ── 工具 ────────────────────────────────────────────

  static Future<bool> _canUseShizuku() async {
    final status = await ShellCopyService.checkShizuku();
    return status['available'] == true && status['hasPermission'] == true;
  }

  static String formatResultSummary(List<DeleteResult> results) {
    final ok = results.where((r) => r.success).length;
    final fail = results.where((r) => !r.success).length;
    return "成功 $ok, 失败 $fail";
  }

  static String _parentDir(String path) {
    final isAbsolute = path.startsWith('/');
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length <= 1) return isAbsolute ? '/' : '';
    final result = parts.sublist(0, parts.length - 1).join('/');
    return isAbsolute ? '/$result' : result;
  }
}
