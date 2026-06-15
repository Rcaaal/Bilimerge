import "dart:convert";
import "dart:io";
import "../models/bili_video.dart";
import "shell_copy_service.dart";

/// 扫描诊断信息
class ScanDiagnostic {
  int totalDirsChecked = 0;
  int totalMediaDirsFound = 0;
  int totalVideosParsed = 0;
  int totalEntryJsonFound = 0;
  int totalEntryJsonMissing = 0;
  final List<String> samplePaths = [];
  final List<String> parseDetails = []; // 每个视频的解析详情

  String get summary {
    final buf = StringBuffer();
    buf.write("扫描了 $totalDirsChecked 个目录");
    if (totalMediaDirsFound > 0) {
      buf.write("，找到 $totalMediaDirsFound 个视频目录");
    }
    if (totalVideosParsed > 0) {
      buf.write("，成功解析 $totalVideosParsed 个视频");
      buf.write("（entry.json 找到 $totalEntryJsonFound 个，缺失 $totalEntryJsonMissing 个）");
    }
    if (samplePaths.isNotEmpty) {
      buf.write("\n示例路径：\n");
      for (final p in samplePaths.take(3)) {
        buf.write("  $p\n");
      }
    }
    if (parseDetails.isNotEmpty) {
      buf.write("\n解析详情：\n");
      for (final d in parseDetails.take(4)) {
        buf.write("  $d\n");
      }
    }
    return buf.toString();
  }
}

class _MediaDir {
  final String avidName;
  final String mediaPath; // 包含 video.m4s 的目录
  final String? entryJsonPath;
  _MediaDir(this.avidName, this.mediaPath, this.entryJsonPath);
}

class BiliParser {
  /// 扫描根目录，自动查找所有含 video.m4s+audio.m4s 的内层目录
  /// 不依赖固定目录层级，只要目录树里有 video.m4s+audio.m4s 成对出现即可识别
  /// [originIndex] 可选，全量复制时记录的原始 Android/data 路径映射
  static Future<List<BiliVideo>> scanRootDirectory(
    String rootPath, {
    ScanDiagnostic? diagnostic,
    Map<String, String>? originIndex,
  }) async {
    final rootDir = Directory(rootPath);
    if (!await rootDir.exists()) return [];

    // 如果未传入 originIndex，尝试从根目录读取 .origin_index.json
    final Map<String, String> resolvedOrigin = originIndex ??
        _loadOriginIndex(rootPath);

    final mediaDirs = <_MediaDir>[];
    await _walkForMedia(rootDir, 0, 10, rootDir.path, mediaDirs, diagnostic);

    final videos = <BiliVideo>[];
    for (final md in mediaDirs) {
      try {
        final video = BiliVideo.fromMediaFolder(
          md.mediaPath,
          md.avidName,
          entryJsonPath: md.entryJsonPath,
          // 查找此 avid 对应的原始源路径
          originalSourceDir: resolvedOrigin[md.avidName],
        );
        videos.add(video);
        if (diagnostic != null) {
          diagnostic.totalVideosParsed++;
          final hasEntry = md.entryJsonPath != null;
          if (hasEntry) {
            diagnostic.totalEntryJsonFound++;
            // 读取 file.json 前 80 字符用于诊断
            try {
              final bytes = File(md.entryJsonPath!).readAsBytesSync();
              final preview = bytes.length > 80 ? bytes.sublist(0, 80) : bytes;
              diagnostic.parseDetails.add(
                "${md.avidName} → JSON开头: ${String.fromCharCodes(preview)}"
              );
            } catch (e) {
              diagnostic.parseDetails.add("${md.avidName} → 读entry.json失败: $e");
            }
          } else {
            diagnostic.totalEntryJsonMissing++;
          }
        }
      } catch (_) {
        continue;
      }
    }
    return videos;
  }

  /// 从 Shizuku 仅扫描结果批量构造 BiliVideo（不复制大文件）
  /// 返回 {videos: List<BiliVideo>, diagnostic: String}
  static Map<String, dynamic> buildFromShizukuScan(
    List<ShizukuScanResult> results,
    String tempPath,
  ) {
    final videos = <BiliVideo>[];
    int ok = 0, fail = 0;
    for (final sr in results) {
      try {
        final video = BiliVideo.fromShizukuScan(
          mediaPath: sr.originalMediaPath,
          tempPath: "$tempPath/${sr.avidFolderName}",
          entryJsonText: sr.entryJsonText,
          avidFolderName: sr.avidFolderName,
        );
        if (video.title.isEmpty || video.title == "未知视频") {
          fail++;
          continue;
        }
        ok++;
        videos.add(video);
      } catch (_) {
        fail++;
      }
    }
    return {'videos': videos, 'diagnostic': "JSON 解析: $ok 成功, $fail 失败"};
  }

  /// 递归遍历目录树，找到所有含 video.m4s+audio.m4s 的目录
  /// [rootPath] 仅用于 avidName 计算（截取相对路径）
  static Future<void> _walkForMedia(
    Directory dir,
    int currentDepth,
    int maxDepth,
    String rootPath,
    List<_MediaDir> results,
    ScanDiagnostic? diagnostic,
  ) async {
    if (currentDepth > maxDepth) return;
    try {
      await for (final entity in dir.list()) {
        if (entity is! Directory) continue;
        if (diagnostic != null) diagnostic.totalDirsChecked++;

        // 关键检查：当前目录是否有 video.m4s + audio.m4s
        final videoFile = File("${entity.path}/video.m4s");
        final audioFile = File("${entity.path}/audio.m4s");
        if (videoFile.existsSync() && audioFile.existsSync()) {
          // ★ 向上遍历祖先目录找 entry.json，直到文件系统根目录
          String? entryPath;
          Directory? ancestor = dir;
          while (ancestor != null) {
            final ef = File("${ancestor.path}/entry.json");
            if (ef.existsSync()) { entryPath = ef.path; break; }
            final parent = ancestor.parent;
            if (parent.path == ancestor.path) break; // 已到文件系统根 /
            ancestor = parent;
          }

          // ★ avidName：取 rootPath 下一级目录名（首个子目录名）
          String avidName;
          try {
            final relative = entity.path.substring(rootPath.length);
            final parts = relative.split(Platform.pathSeparator).where((p) => p.isNotEmpty).toList();
            avidName = parts.isNotEmpty ? parts.first : dir.uri.pathSegments.last;
          } catch (_) {
            avidName = dir.uri.pathSegments.last;
          }

          results.add(_MediaDir(avidName, entity.path, entryPath));
          if (diagnostic != null) {
            diagnostic.totalMediaDirsFound++;
            if (diagnostic.samplePaths.length < 3) {
              diagnostic.samplePaths.add(entity.path);
            }
          }
        }

        // 继续递归
        await _walkForMedia(
          entity,
          currentDepth + 1,
          maxDepth,
          rootPath,
          results,
          diagnostic,
        );
      }
    } catch (_) {}
  }

  /// 验证目录是否包含任何 video.m4s
  static Future<bool> isValidRootDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return false;
    try {
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          if (File("${entity.path}/video.m4s").existsSync()) return true;
          await for (final sub in entity.list()) {
            if (sub is Directory && File("${sub.path}/video.m4s").existsSync()) return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  static Future<void> deleteFolder(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 从根目录加载 Shizuku 全量复制时保存的原始路径索引
  ///
  /// `.origin_index.json` 由 [ShellCopyService.copyViaShizuku] 写入，
  /// 格式: { "avidFolderName": "/Android/data/.../avidFolderName", ... }
  static Map<String, String> _loadOriginIndex(String rootPath) {
    try {
      final indexFile = File("$rootPath/.origin_index.json");
      if (indexFile.existsSync()) {
        final data = jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
        return data.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    return const {};
  }
}
