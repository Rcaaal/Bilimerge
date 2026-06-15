import "dart:convert";
import "dart:io";
import "dart:typed_data";
import "package:flutter/services.dart";
import "package:path_provider/path_provider.dart";

/// Shizuku 仅扫描结果（含诊断信息）
class ShizukuScanResult {
  final String originalMediaPath;
  final String avidFolderName;
  final String entryJsonText;
  final String? diagnostic;
  ShizukuScanResult(this.originalMediaPath, this.avidFolderName, this.entryJsonText, {this.diagnostic});
}

/// Android/Data 文件访问方案
class ShellCopyService {
  static String? _tempDir;
  static bool _initialized = false;

  /// 仅扫描临时目录（每次扫描前清空）
  static Future<String> get tempDir async {
    if (_tempDir == null) {
      final appDir = await getApplicationDocumentsDirectory();
      _tempDir = "${appDir.path}/BiliTempCache";
    }
    return _tempDir!;
  }

  /// 全量复制专用目录（只有手动清理或改用仅扫描时才会清空）
  static String? _fullCopyDir;

  static Future<String> get fullCopyDir async {
    if (_fullCopyDir == null) {
      final appDir = await getApplicationDocumentsDirectory();
      _fullCopyDir = "${appDir.path}/BiliFullCopyCache";
    }
    return _fullCopyDir!;
  }

  static Future<String> getFullCopyPath() async => await fullCopyDir;

  /// 清空全量复制缓存（手动清理或切换到仅扫描时调用）
  static Future<void> cleanFullCopyTemp() async {
    final dir = Directory(await fullCopyDir);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
  }

  // ─── SAF ──────────────────────────────────────────

  static Future<int> copyViaSaf(String safUri) async {
    const channel = MethodChannel("com.personal.bilimerge/merge");
    final dest = await tempDir;
    await cleanTemp();
    try {
      final result = await channel.invokeMethod<int>("copyFromSafUri", {
        "safUri": safUri,
        "destPath": dest,
      });
      return result ?? 0;
    } on PlatformException catch (e) {
      print("SAF copy failed: ${e.message}");
      return 0;
    } catch (e) {
      print("SAF copy error: $e");
      return 0;
    }
  }

  static bool isSafUri(String path) => path.startsWith("content://");

  // ─── Shizuku ──────────────────────────────────────

  static const _channel = MethodChannel("com.personal.bilimerge/merge");

  static Future<Map<String, dynamic>> checkShizuku() async {
    try {
      final result = await _channel.invokeMethod<Map>('checkShizuku');
      return Map<String, dynamic>.from(result ?? {'available': false, 'hasPermission': false});
    } catch (e) {
      return {'available': false, 'hasPermission': false, 'error': '$e'};
    }
  }

  static Future<bool> requestShizukuPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestShizukuPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> executeShellViaShizuku(String command) async {
    try {
      final result = await _channel.invokeMethod<Map>('executeShellViaShizuku', {
        'command': command,
      });
      return Map<String, dynamic>.from(result ?? {'exitCode': -1, 'stdout': '', 'stderr': 'No result'});
    } on PlatformException catch (e) {
      return {'exitCode': -1, 'stdout': '', 'stderr': e.message ?? 'Shizuku error'};
    } catch (e) {
      return {'exitCode': -1, 'stdout': '', 'stderr': '$e'};
    }
  }

  // ─── 全量复制（流式，零大内存分配，独立目录）───────

  /// 流式复制单个文件（Shizuku cat + Java FileOutputStream + 64KB buffer）
  /// 零大内存分配，适用于大文件；创建目标父目录再复制
  static Future<bool> streamSingleFile(String src, String dst) async {
    try {
      final parentDir = File(dst).parent;
      if (!parentDir.existsSync()) parentDir.createSync(recursive: true);

      final result = await _channel.invokeMethod<bool>('streamSingleFile', {
        'src': src,
        'dst': dst,
      });
      return result ?? false;
    } catch (e) {
      print("streamSingleFile error: $e");
      return false;
    }
  }

  /// 全量复制 B 站缓存到独立目录 [BiliFullCopyCache]
  ///
  /// 与仅扫描不同：
  ///   - 复制完整的 video.m4s + audio.m4s（非仅元数据）
  ///   - 使用独立目录 [fullCopyDir]，不清空仅扫描的 [tempDir]
  ///   - 目录仅手动清理或切换到仅扫描时清空
  ///
  /// 复制流程（流式，Shizuku 读 → Java 写，零大内存分配）：
  ///   1. Shizuku find 找所有 video.m4s 目录（只读）
  ///   2. 对每个目录：streamSingleFile(video.m4s, audio.m4s, entry.json, cover.jpg)
  static Future<bool> copyViaShizuku({
    required String sourceDir,
    void Function(String currentFile, int done, int total)? onProgress,
  }) async {
    final dest = await fullCopyDir;
    // 不调用 cleanTemp / cleanFullCopyTemp — 全量复制目录持久保留

    try {
      final scanResult = await executeShellViaShizuku(
        "find '$sourceDir' -name 'video.m4s' -exec dirname {} \\; 2>/dev/null",
      );
      if (scanResult['exitCode'] != 0 && scanResult['exitCode'] != 1) {
        return false;
      }
      final mediaDirs = (scanResult['stdout'] as String)
          .split("\n").where((l) => l.trim().isNotEmpty).toList();
      if (mediaDirs.isEmpty) return false;

      // 收集原始路径映射：avidFolderName → 原始 avid 目录路径
      final Map<String, String> originIndex = {};

      bool allOk = true;
      for (int i = 0; i < mediaDirs.length; i++) {
        final md = mediaDirs[i].trim();
        if (md.isEmpty) continue;
        final parentDir = md.substring(0, md.lastIndexOf("/"));
        final avid = md.replaceFirst(sourceDir, '').split('/').where((p) => p.isNotEmpty).first;
        final relPath = md.startsWith(sourceDir)
            ? md.substring(sourceDir.length).replaceFirst("/", "")
            : md.split("/").last;
        final targetDir = "$dest/$relPath";
        final qn = md.split('/').last;

        // 记录原始 avid 目录路径
        originIndex[avid] = parentDir;

        onProgress?.call("$avid/$qn", i + 1, mediaDirs.length);

        // 流式复制每个文件（不分配大内存）
        final vOk = await streamSingleFile('$md/video.m4s', '$targetDir/video.m4s');
        final aOk = await streamSingleFile('$md/audio.m4s', '$targetDir/audio.m4s');
        final eOk = await streamSingleFile('$parentDir/entry.json', '$targetDir/../entry.json');
        // cover.jpg 和 index.json 非必需，失败不中断
        await streamSingleFile('$parentDir/cover.jpg', '$targetDir/../cover.jpg');
        await streamSingleFile('$md/index.json', '$targetDir/index.json');

        if (!vOk || !aOk) allOk = false;
      }

      // 保存原始路径索引，供删除时定位 Android/data 源文件
      try {
        final indexFile = File('$dest/.origin_index.json');
        indexFile.writeAsStringSync(jsonEncode(originIndex));
      } catch (_) {}

      return allOk;
    } catch (e) {
      print("Shizuku copy error: $e");
      return false;
    }
  }

  // ─── 仅扫描：base64 管道（管道无损传输） ───────────

  /// 通过 base64 编码管道读取 entry.json，再用 Dart File.write
  /// 写入临时目录。base64 只有 ASCII，管道无截断风险。
  /// [coversDir] 封面存储目录（应用 documents，不清除）
  static Future<Map<String, dynamic>> scanViaShizuku(
    String sourceDir, {
    void Function(String currentFile, int done, int total)? onProgress,
    String? coversDir,
  }) async {
    final dest = await tempDir;
    await cleanTemp();
    final results = <ShizukuScanResult>[];
    final diag = StringBuffer();
    diag.writeln("源目录: $sourceDir");

    final scanOut = await executeShellViaShizuku(
      "find '$sourceDir' -name 'video.m4s' -exec dirname {} \\; 2>/dev/null",
    );
    if (scanOut['exitCode'] != 0 && scanOut['exitCode'] != 1) {
      return {'results': <ShizukuScanResult>[], 'diagnostic': 'find failed'};
    }
    final mediaDirs = (scanOut['stdout'] as String)
        .split("\n").where((l) => l.trim().isNotEmpty).toList();
    diag.writeln("找到 ${mediaDirs.length} 个视频目录");

    for (int i = 0; i < mediaDirs.length; i++) {
      final dir = mediaDirs[i].trim();
      if (dir.isEmpty) continue;
      final parentDir = dir.substring(0, dir.lastIndexOf("/"));
      final avid = dir.replaceFirst(sourceDir, '').split('/').where((p) => p.isNotEmpty).first;

      onProgress?.call(avid, i, mediaDirs.length);

      // 用 base64 读取 entry.json（-w0 禁用换行，纯 ASCII 管道）
      final r = await executeShellViaShizuku(
        "base64 -w0 '${parentDir}/entry.json' 2>/dev/null; echo",
      );
      if (r['exitCode'] == 0) {
        // 去除所有空白字符（Java readLine 可能引入 \n 等）
        final b64 = (r['stdout'] as String).replaceAll(RegExp(r'\s'), '');
        if (b64.isNotEmpty) {
          try {
            final bytes = base64Decode(b64);
            final text = utf8.decode(bytes);
            if (text.trim().isNotEmpty) {
              results.add(ShizukuScanResult(dir, avid, text));

              // base64 读 cover.jpg → 写本地持久目录（含 avid 子目录）
              final coverSaveDir = coversDir != null ? '$coversDir/$avid' : '$dest/$avid';
              final rc = await executeShellViaShizuku(
                "base64 -w0 '${parentDir}/cover.jpg' 2>/dev/null; echo",
              );
              if (rc['exitCode'] == 0) {
                final coverB64 = (rc['stdout'] as String).replaceAll(RegExp(r'\s'), '');
                if (coverB64.isNotEmpty) {
                  try {
                    final coverBytes = base64Decode(coverB64);
                    Directory(coverSaveDir).createSync(recursive: true);
                    File('$coverSaveDir/cover.jpg').writeAsBytesSync(coverBytes);
                  } catch (_) {}
                }
              }

              // base64 读 index.json → 写本地（含大小/分辨率信息）
              final qn = dir.split('/').last;
              final ri = await executeShellViaShizuku(
                "base64 -w0 '${dir}/index.json' 2>/dev/null; echo",
              );
              if (ri['exitCode'] == 0) {
                final idxB64 = (ri['stdout'] as String).replaceAll(RegExp(r'\s'), '');
                if (idxB64.isNotEmpty) {
                  try {
                    final idxBytes = base64Decode(idxB64);
                    Directory('$dest/$avid/$qn').createSync(recursive: true);
                    File('$dest/$avid/$qn/index.json').writeAsBytesSync(idxBytes);
                  } catch (_) {}
                }
              }
            } else { diag.writeln("$avid: empty after decode"); }
          } catch (e) { diag.writeln("$avid: base64 decode fail: $e"); }
        } else { diag.writeln("$avid: base64 empty"); }
      } else { diag.writeln("$avid: base64 exit=${r['exitCode']}"); }
    }

    diag.writeln("成功解析 ${results.length} 个视频");
    return {'results': results, 'diagnostic': diag.toString(), 'count': results.length};
  }

  // ─── 读取原始文件字节（绕过 BufferedReader 编码损坏） ──

  /// 通过 Shizuku 读取文件原始字节（用于大文件复制）
  /// 返回 Uint8List?，null 表示失败
  static Future<Uint8List?> readFileBytes(String filePath) async {
    try {
      final result = await _channel.invokeMethod<Uint8List?>('readFileBytes', {
        'filePath': filePath,
      });
      return result;
    } catch (e) {
      print("readFileBytes error: $e");
      return null;
    }
  }

  // ─── 流式复制（native 64KB buffer，零大内存分配） ───

  /// 通过 native 端用 Shizuku cat + 64KB buffer 直写文件
  /// 不分配大内存，避免大文件 OOM 闪退
  static Future<bool> copyFileForExportViaShizuku({
    required String originalMediaPath,
    required String destMediaPath,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('copyFileForExport', {
        'originalMediaPath': originalMediaPath,
        'destMediaPath': destMediaPath,
      });
      return result ?? false;
    } catch (e) {
      print("copyFileForExport error: $e");
      return false;
    }
  }

  // ─── 按需复制：Dart 创建目录 + 读取原始字节写入 ───

  /// Dart 创建目录，Shizuku 流式复制（64KB buffer），Dart 无需分配大内存
  /// 旧版 readFileBytes 将整个文件读入 Uint8List 导致大视频 OOM 闪退
  static Future<bool> copyForExportViaShizuku({
    required String originalMediaPath,
    required String destMediaPath,
  }) async {
    // 使用 native 流式复制，零大内存分配
    return copyFileForExportViaShizuku(
      originalMediaPath: originalMediaPath,
      destMediaPath: destMediaPath,
    );
  }

  // ─── Shell ────────────────────────────────────────

  static Future<bool> isShellAvailable() async {
    try {
      final result = await Process.run("sh", ["-c", "echo ok"], runInShell: true);
      return result.exitCode == 0;
    } catch (_) { return false; }
  }

  static Future<bool> isRootAvailable() async {
    try {
      final result = await Process.run("su", ["-c", "echo ok"], runInShell: true);
      return result.exitCode == 0;
    } catch (_) { return false; }
  }

  static Future<bool> copyViaShell({
    required String sourceDir,
    void Function(String currentFile, int done, int total)? onProgress,
  }) async {
    final bool hasRoot = await isRootAvailable();
    final bool hasSh = hasRoot || await isShellAvailable();
    if (!hasRoot && !hasSh) return false;
    final shellExe = hasRoot ? "su" : "sh";
    final dest = await tempDir;
    await cleanTemp();
    try {
      final scanResult = await Process.run(shellExe, ["-c",
        "find '$sourceDir' -name 'video.m4s' -exec dirname {} \\; 2>/dev/null"], runInShell: true);
      if (scanResult.exitCode != 0) return false;
      final mediaDirs = scanResult.stdout.toString().split("\n").where((l) => l.trim().isNotEmpty).toList();
      if (mediaDirs.isEmpty) return false;
      for (int i = 0; i < mediaDirs.length; i++) {
        final md = mediaDirs[i].trim();
        final relPath = md.startsWith(sourceDir)
            ? md.substring(sourceDir.length).replaceFirst("/", "") : md.split("/").last;
        final targetDir = "$dest/$relPath";
        onProgress?.call(md, i + 1, mediaDirs.length);
        await Process.run(shellExe, ["-c",
          "mkdir -p '$targetDir' && "
          "cp '$md/video.m4s' '$targetDir/' 2>/dev/null; "
          "cp '$md/audio.m4s' '$targetDir/' 2>/dev/null; "
          "cp '${md.substring(0, md.lastIndexOf("/"))}/entry.json' '$targetDir/../' 2>/dev/null; "
          "cp '${md.substring(0, md.lastIndexOf("/"))}/cover.jpg' '$targetDir/../' 2>/dev/null; "
          "true"], runInShell: true);
      }
      return true;
    } catch (_) { return false; }
  }

  // ─── MT Manager ──────────────────────────────────

  /// 复制文本到剪贴板
  static Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 用指定命令打开路径（用于手动删除时跳转文件管理器）
  ///
  /// [commandTemplate] 包含 {path} 占位符，如：
  ///   "am start -a android.intent.action.VIEW -d 'file://{path}'"
  /// [path] 将被 shell 转义后替换 {path}
  static Future<bool> launchAppWithPath({
    required String commandTemplate,
    required String path,
  }) async {
    try {
      final escapedPath = path.replaceAll("'", "'\\''");
      final command = commandTemplate.replaceAll("{path}", escapedPath);
      final result = await Process.run("sh", ["-c", command], runInShell: true);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 通过 Shizuku 写入文本文件（用于创建删除标记文件）
  ///
  /// [filePath] 要写入的文件路径
  /// [content] 文本内容
  /// 返回 true = 写入成功
  static Future<bool> writeTextFileViaShizuku({
    required String filePath,
    required String content,
  }) async {
    final result = await executeShellViaShizuku(
      "echo '${content.replaceAll("'", "'\\''")}' > '$filePath' 2>&1",
    );
    return result['exitCode'] == 0;
  }

  /// 启动 MT 管理器，可选导航到指定路径
  ///
  /// [path] 如提供，会尝试用 `file://` URI 让 MT 管理器直接打开该目录。
  /// 如果路径导航失败，至少已复制到剪贴板。
  static Future<bool> launchMTManager({String? path}) async {
    const pkgs = ["bin.mt.plus", "bin.mt.plus.canary", "com.mt.rootmanager"];

    // 如果提供了路径，先复制到剪贴板
    if (path != null && path.isNotEmpty) {
      await copyToClipboard(path);
    }

    for (final pkg in pkgs) {
      try {
        // 优先尝试带路径的 intent
        if (path != null && path.isNotEmpty) {
          final encodedPath = path
              .replaceAll("'", "'\\''"); // shell 转义单引号
          final result = await Process.run("sh", [
            "-c",
            "am start -a android.intent.action.VIEW "
            "-n '$pkg/.MainActivity' "
            "-d 'file://$encodedPath' 2>/dev/null || "
            "am start -n '$pkg/.MainActivity' 2>/dev/null || "
            "am start -a android.intent.action.MAIN -p '$pkg' 2>/dev/null"
          ], runInShell: true);
          if (result.exitCode == 0) return true;
        } else {
          final result = await Process.run("sh", [
            "-c",
            "am start -n '$pkg/.MainActivity' 2>/dev/null || "
            "am start -a android.intent.action.MAIN -p '$pkg' 2>/dev/null"
          ], runInShell: true);
          if (result.exitCode == 0) return true;
        }
      } catch (_) { continue; }
    }
    return false;
  }

  /// 通过 Shizuku 执行 `rm -rf` 删除路径（多策略 + 详细错误）
  ///
  /// 返回 map: {success: bool, exitCode: int, stdout: String, stderr: String, detail: String?}
  static Future<Map<String, dynamic>> deletePathViaShizuku(String path) async {
    try {
      final result = await _channel.invokeMethod<Map>('deletePath', {
        'path': path,
      });
      return Map<String, dynamic>.from(result ?? {
        'success': false, 'exitCode': -1, 'stdout': '', 'stderr': 'No result'
      });
    } catch (e) {
      return {'success': false, 'exitCode': -1, 'stdout': '', 'stderr': '$e'};
    }
  }

  /// 通过 SAF ContentProvider 删除目录（实验性，不走 shell 路径）
  ///
  /// 尝试三种方式：
  ///   1. DocumentsContract.deleteDocument() — Java ContentResolver API
  ///   2. content delete shell — 走 ContentProvider binder
  ///   3. rm -rf via Shizuku — 兜底
  ///
  /// 返回 map: {success: bool, method: String, attempts: Map, error: String?}
  static Future<Map<String, dynamic>> deleteViaSaf(String absolutePath) async {
    try {
      final result = await _channel.invokeMethod<Map>('deleteViaSaf', {
        'path': absolutePath,
      });
      return Map<String, dynamic>.from(result ?? {'success': false, 'error': 'No result'});
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }

  /// 通过 Android Intent 打开文件夹（系统弹出 App 选择器）
  ///
  /// 比 `am start` 更可靠，因为走原生 Android Intent API。
  /// 用户可以在选择器中自由选择文件管理器（可设为默认）。
  static Future<bool> openFolder({required String path}) async {
    try {
      final result = await _channel.invokeMethod<bool>('openFolder', {
        'path': path,
      });
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  // ─── 辅助 ─────────────────────────────────────────

  static Future<int> countMediaDirs(String sourceDir) async {
    try {
      final result = await Process.run("sh", ["-c",
        "find '$sourceDir' -name 'video.m4s' 2>/dev/null | wc -l"], runInShell: true);
      return int.tryParse(result.stdout.toString().trim()) ?? 0;
    } catch (_) { return 0; }
  }

  static Future<String> getSourceSize(String sourceDir) async {
    try {
      final result = await Process.run("sh", ["-c",
        "du -sh '$sourceDir' 2>/dev/null | cut -f1"], runInShell: true);
      return result.stdout.toString().trim();
    } catch (_) { return "unknown"; }
  }

  static Future<void> cleanTemp() async {
    final dir = Directory(await tempDir);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
  }

  static Future<String> getTempPath() async => await tempDir;

  static bool isInTempDir(String path) {
    if (_tempDir == null) return false;
    return path.startsWith(_tempDir!);
  }
}
