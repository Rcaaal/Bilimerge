import "dart:convert";
import "dart:io";

/// Bilibili 视频缓存条目
class BiliVideo {
  final String cid;
  final String folderPath;
  final String avid;
  final String avidFolderName;
  final String bvid;
  final String title;
  final String ownerName;
  final int durationMs;
  final int qualityTag;
  final String qualityLabel;
  final int width;
  final int height;
  final double frameRate;
  final String coverPath;
  final String audioPath;
  final String videoPath;
  final int audioSize;
  final int videoSize;
  final int danmakuCount;
  final int downloadTimestamp;
  /// 原始缓存目录路径（在 Android/data 中，qn 级别），仅扫描模式使用
  final String? originalMediaPath;
  /// 原始源文件 avid 文件夹路径（Android/data 中的 avid 层级），
  /// 由 fromShizukuScan 或 fromMediaFolder（全量复制）填充，
  /// 用于 DeleteService 定位真正的删除目标
  final String? originalSourceFolder;
  String? mergeOutputPath;

  bool get isMerged => mergeOutputPath != null;
  int get totalBytes => videoSize + audioSize;
  /// 是否仅扫描模式（m4s 文件未复制到本地）
  bool get isScanOnly => originalMediaPath != null;

  BiliVideo({
    required this.cid,
    required this.folderPath,
    required this.avid,
    required this.avidFolderName,
    required this.bvid,
    required this.title,
    required this.ownerName,
    required this.durationMs,
    required this.qualityTag,
    required this.qualityLabel,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.coverPath,
    required this.audioPath,
    required this.videoPath,
    required this.audioSize,
    required this.videoSize,
    this.danmakuCount = 0,
    this.downloadTimestamp = 0,
    this.mergeOutputPath,
    this.originalMediaPath,
    this.originalSourceFolder,
  });

  /// 从包含 video.m4s+audio.m4s 的目录解析视频信息（容错版）
  /// [mediaPath] 是直接包含 video.m4s 和 audio.m4s 的目录
  /// [entryJsonPath] 可选，用于获取元数据
  /// [originalSourceDir] 可选，原始 Android/data 中的 avid 目录路径（全量复制时用于记录删除目标）
  factory BiliVideo.fromMediaFolder(
    String mediaPath,
    String avidFolderName, {
    String? entryJsonPath,
    String? originalSourceDir,
  }) {
    String? title, ownerName, bvid, avidStr, qualityLabel;
    int durationMs = 0, danmakuCount = 0, downloadTimestamp = 0;
    int vW = 0, vH = 0;
    double fps = 0;

    // 读取 entry.json 获取元数据（遍历祖先链直到找到为止）
    String? resolvedEntryPath = entryJsonPath;
    if (resolvedEntryPath != null && File(resolvedEntryPath).existsSync()) {
      // 已有有效路径，跳过搜索
    } else {
      // 从 mediaPath 开始逐层向上找 entry.json
      resolvedEntryPath = null;
      final sep = Platform.pathSeparator;
      // 从 mediaPath 自身开始检查，然后逐层向上
      String checkPath = mediaPath;
      while (true) {
        final ef = File("$checkPath/entry.json");
        if (ef.existsSync()) { resolvedEntryPath = ef.path; break; }
        // 向上走一层
        final lastSlash = checkPath.lastIndexOf(sep);
        if (lastSlash <= 0) break; // 到了根目录
        checkPath = checkPath.substring(0, lastSlash);
      }
    }
    if (resolvedEntryPath != null) {
      try {
        final ef = File(resolvedEntryPath!);
        if (ef.existsSync()) {
          // 以字节方式读取，清除可能的 BOM 头
          final bytes = ef.readAsBytesSync();
          // 去除 UTF-8 BOM (0xEF, 0xBB, 0xBF)
          final cleanBytes = (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
              ? bytes.sublist(3)
              : bytes;
          // 去除 UTF-16 LE BOM (0xFF, 0xFE)
          final noBom = (cleanBytes.length >= 2 && cleanBytes[0] == 0xFF && cleanBytes[1] == 0xFE)
              ? cleanBytes.sublist(2)
              : cleanBytes;
          final jsonStr = utf8.decode(noBom, allowMalformed: true);
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          // ★★★ 从 entry.json 提取字段 ★★★
          title = _safeString(json["title"]);
          ownerName = _safeString(json["owner_name"]);
          bvid = _safeString(json["bvid"]);
          avidStr = _safeString(json["avid"]);
          qualityLabel = _safeString(json["quality_pithy_description"]);
          durationMs = _safeInt(json["total_time_milli"]) ?? 0;
          danmakuCount = _safeInt(json["danmaku_count"]) ?? 0;
          downloadTimestamp = _safeInt(json["time_create_stamp"]) ?? 0;
        }
      } catch (_) {}
    }

    // 质量标签：从目录名推断（兜底）
    final qualityName = mediaPath.split(Platform.pathSeparator).last;
    final intQuality = int.tryParse(qualityName) ?? 0;
    if (qualityLabel == null || qualityLabel!.isEmpty) {
      qualityLabel = intQuality >= 120 ? "4K"
                  : intQuality >= 100 ? "1080P+"
                  : intQuality >= 80  ? "1080P"
                  : intQuality >= 64  ? "720P"
                  : "${intQuality}P";
    }

    // 尝试读取 index.json（尺寸、帧率、文件大小）
    final indexFile = "$mediaPath/index.json";
    int vSize = 0, aSize = 0;
    if (File(indexFile).existsSync()) {
      try {
        final idx = jsonDecode(File(indexFile).readAsStringSync()) as Map<String, dynamic>;
        if (idx["video"] is List && (idx["video"] as List).isNotEmpty) {
          final vi = (idx["video"] as List).first as Map<String, dynamic>;
          vSize = _safeInt(vi["size"]) ?? 0;
          vW = _safeInt(vi["width"]) ?? vW;
          vH = _safeInt(vi["height"]) ?? vH;
          fps = _safeDouble(vi["frame_rate"]) ?? 0;
        }
        if (idx["audio"] is List && (idx["audio"] as List).isNotEmpty) {
          final ai = (idx["audio"] as List).first as Map<String, dynamic>;
          aSize = _safeInt(ai["size"]) ?? 0;
        }
      } catch (_) {}
    }

    final cid = "c_${avidFolderName}_$qualityName";

    return BiliVideo(
      cid: cid,
      folderPath: mediaPath,
      avid: avidStr ?? avidFolderName,
      avidFolderName: avidFolderName,
      bvid: bvid ?? "",
      title: title ?? "未知视频",
      ownerName: ownerName ?? "未知UP主",
      durationMs: durationMs,
      qualityTag: intQuality,
      qualityLabel: qualityLabel,
      width: vW,
      height: vH,
      frameRate: fps,
      coverPath: "${Directory(mediaPath).parent.path}/cover.jpg",
      audioPath: "$mediaPath/audio.m4s",
      videoPath: "$mediaPath/video.m4s",
      audioSize: aSize,
      videoSize: vSize,
      danmakuCount: danmakuCount,
      downloadTimestamp: downloadTimestamp,
      originalSourceFolder: originalSourceDir,
    );
  }

  /// 从 Shizuku 仅扫描结果构造 BiliVideo（不要求 video.m4s 文件本地存在）
  /// [mediaPath] 原始 Android/data 中包含 video.m4s 的目录路径
  /// [tempPath] 临时目录中该视频的上级路径（含 entry.json + cover.jpg）
  /// [entryJsonText] entry.json 文本内容
  /// [avidFolderName] avid 文件夹名
  factory BiliVideo.fromShizukuScan({
    required String mediaPath,
    required String tempPath,
    required String entryJsonText,
    required String avidFolderName,
  }) {
    String? title, ownerName, bvid, avidStr, qualityLabel;
    int durationMs = 0, danmakuCount = 0, downloadTimestamp = 0;
    int vW = 0, vH = 0;
    double fps = 0;

    // 解析 entry.json 文本（兼容 BOM）
    try {
      String cleanJson = entryJsonText;
      if (cleanJson.isNotEmpty && cleanJson.codeUnitAt(0) == 0xFEFF) {
        cleanJson = cleanJson.substring(1);
      }
      final json = jsonDecode(cleanJson) as Map<String, dynamic>;
      title = _safeString(json["title"]);
      ownerName = _safeString(json["owner_name"]);
      bvid = _safeString(json["bvid"]);
      avidStr = _safeString(json["avid"]);
      qualityLabel = _safeString(json["quality_pithy_description"]);
      durationMs = _safeInt(json["total_time_milli"]) ?? 0;
      danmakuCount = _safeInt(json["danmaku_count"]) ?? 0;
      downloadTimestamp = _safeInt(json["time_create_stamp"]) ?? 0;
    } catch (_) {}

    // 从目录名推断质量标签
    final qualityName = mediaPath.split("/").last;
    final intQuality = int.tryParse(qualityName) ?? 0;
    if (qualityLabel == null || qualityLabel.isEmpty) {
      qualityLabel = intQuality >= 120 ? "4K"
                  : intQuality >= 100 ? "1080P+"
                  : intQuality >= 80  ? "1080P"
                  : intQuality >= 64  ? "720P"
                  : "${intQuality}P";
    }

    // 尝试读取临时目录中的 index.json（获取尺寸和大小）
    int vSize = 0, aSize = 0;
    final indexFile = "$tempPath/$qualityName/index.json";
    if (File(indexFile).existsSync()) {
      try {
        final idx = jsonDecode(File(indexFile).readAsStringSync()) as Map<String, dynamic>;
        if (idx["video"] is List && (idx["video"] as List).isNotEmpty) {
          final vi = (idx["video"] as List).first as Map<String, dynamic>;
          vSize = _safeInt(vi["size"]) ?? 0;
          vW = _safeInt(vi["width"]) ?? vW;
          vH = _safeInt(vi["height"]) ?? vH;
          fps = _safeDouble(vi["frame_rate"]) ?? 0;
        }
        if (idx["audio"] is List && (idx["audio"] as List).isNotEmpty) {
          final ai = (idx["audio"] as List).first as Map<String, dynamic>;
          aSize = _safeInt(ai["size"]) ?? 0;
        }
      } catch (_) {}
    }

    final cid = "c_${avidFolderName}_$qualityName";

    return BiliVideo(
      cid: cid,
      folderPath: tempPath,
      avid: avidStr ?? avidFolderName,
      avidFolderName: avidFolderName,
      bvid: bvid ?? "",
      title: title ?? "未知视频",
      ownerName: ownerName ?? "未知UP主",
      durationMs: durationMs,
      qualityTag: intQuality,
      qualityLabel: qualityLabel,
      width: vW,
      height: vH,
      frameRate: fps,
      coverPath: "$tempPath/cover.jpg",
      audioPath: "$mediaPath/audio.m4s",
      videoPath: "$mediaPath/video.m4s",
      audioSize: aSize,
      videoSize: vSize,
      danmakuCount: danmakuCount,
      downloadTimestamp: downloadTimestamp,
      originalMediaPath: mediaPath,
    );
  }

  factory BiliVideo.fromFolder(String folderPath, String avidFolderName) {
    final entryFile = "$folderPath/entry.json";
    final data = File(entryFile).readAsStringSync();
    final json = jsonDecode(data) as Map<String, dynamic>;

    // ---- 安全取 page_data ----
    Map<String, dynamic> pageData = {};
    if (json["page_data"] is Map) {
      pageData = json["page_data"] as Map<String, dynamic>;
    }

    // ---- 兼容 int / String 的 type_tag ----
    final dynamic rawTag = json["type_tag"];
    String qualityTag;
    if (rawTag is int) {
      qualityTag = rawTag.toString();
    } else {
      qualityTag = (rawTag ?? "80").toString();
    }
    final intQuality = int.tryParse(qualityTag) ?? 80;

    // ---- 查找质量目录：先试指定值，失败则自动扫描 ----
    String qualityDir = "$folderPath/$qualityTag";
    if (!Directory(qualityDir).existsSync()) {
      qualityDir = _findQualityDir(folderPath) ?? qualityDir;
    }

    // ---- 解析 index.json（如果存在） ----
    int vW = _safeInt(pageData["width"]) ?? 0;
    int vH = _safeInt(pageData["height"]) ?? 0;
    double fps = 0;
    int vSize = 0, aSize = 0;

    final indexFile = "$qualityDir/index.json";
    if (File(indexFile).existsSync()) {
      try {
        final idx = jsonDecode(File(indexFile).readAsStringSync()) as Map<String, dynamic>;
        if (idx["video"] is List && (idx["video"] as List).isNotEmpty) {
          final vi = (idx["video"] as List).first as Map<String, dynamic>;
          vSize = _safeInt(vi["size"]) ?? 0;
          vW = _safeInt(vi["width"]) ?? vW;
          vH = _safeInt(vi["height"]) ?? vH;
          fps = _safeDouble(vi["frame_rate"]) ?? 0;
        }
        if (idx["audio"] is List && (idx["audio"] as List).isNotEmpty) {
          final audioMap = (idx["audio"] as List).first as Map<String, dynamic>;
          aSize = _safeInt(audioMap["size"]) ?? 0;
        }
      } catch (_) {
        // index.json 解析失败，用 fallback 值
      }
    }

    final cidVal = "c_${pageData["cid"] ?? ""}";

    // ---- 检查是否已有合并产物 ----
    String? mergedPath;
    final mergedFile = File("$folderPath/${cidVal}_merged.mp4");
    if (mergedFile.existsSync()) mergedPath = mergedFile.path;

    return BiliVideo(
      cid: cidVal,
      folderPath: folderPath,
      avid: _safeString(json["avid"]),
      avidFolderName: avidFolderName,
      bvid: _safeString(json["bvid"]),
      title: _safeString(json["title"]),
      ownerName: _safeString(json["owner_name"]),
      durationMs: _safeInt(json["total_time_milli"]) ?? 0,
      qualityTag: intQuality,
      qualityLabel: _safeString(json["quality_pithy_description"]),
      width: vW,
      height: vH,
      frameRate: fps,
      coverPath: "$folderPath/cover.jpg",
      audioPath: "$qualityDir/audio.m4s",
      videoPath: "$qualityDir/video.m4s",
      audioSize: aSize,
      videoSize: vSize,
      danmakuCount: _safeInt(json["danmaku_count"]) ?? 0,
      downloadTimestamp: _safeInt(json["time_create_stamp"]) ?? 0,
      mergeOutputPath: mergedPath,
    );
  }

  /// 扫描 c_ 目录下第一个含有 video.m4s 的子目录作为质量目录
  static String? _findQualityDir(String folderPath) {
    try {
      final dir = Directory(folderPath);
      final subs = dir.listSync(followLinks: false);
      for (final sub in subs) {
        if (sub is Directory) {
          if (File("${sub.path}/video.m4s").existsSync()) {
            return sub.path;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ---- 安全取值辅助 ----
  static String _safeString(dynamic v) {
    if (v == null) return "";
    if (v is String) return v;
    return v.toString();
  }

  static int? _safeInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static double? _safeDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  // ---- 格式化 ----

  String get durationFormatted {
    final sec = (durationMs / 1000).round();
    return "${sec ~/ 60}:${(sec % 60).toString().padLeft(2, "0")}";
  }

  String get sizeFormatted => _fmt(totalBytes);
  String get videoSizeFormatted => _fmt(videoSize);
  String get audioSizeFormatted => _fmt(audioSize);

  String get exportFileName {
    final cleanTitle = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), "");
    final cleanOwner = ownerName.replaceAll(RegExp(r'[<>:"/\\|?*]'), "");
    const int maxBytes = 240;

    // 从完整 title 开始，逐步截断直到 UTF-8 字节不超限
    for (int len = cleanTitle.length; len >= 0; len--) {
      final truncated = cleanTitle.substring(0, len);
      final name = "#$cleanOwner-$truncated-${_fmt(totalBytes)}.mp4";
      if (utf8.encode(name).length <= maxBytes) {
        return name;
      }
    }
    // 极端 fallback：连空 title 都超限（极少见）
    return "#${cleanOwner.substring(0, cleanOwner.length.clamp(1, 8))}-${_fmt(totalBytes)}.mp4";
  }

  DateTime? get downloadDate =>
      downloadTimestamp > 0 ? DateTime.fromMillisecondsSinceEpoch(downloadTimestamp) : null;

  String get downloadDateFormatted {
    final d = downloadDate;
    if (d == null) return "未知";
    return "${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}";
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }
}
