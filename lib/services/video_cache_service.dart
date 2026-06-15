/// 视频列表缓存服务
/// 保存扫描结果到 JSON 文件，App 重启后自动恢复
import "dart:convert";
import "dart:io";
import "package:path_provider/path_provider.dart";
import "../models/bili_video.dart";

class VideoCacheService {
  static String? _dir;
  static bool _loaded = false;

  static Future<String> get _cacheDir async {
    if (_dir == null) {
      final appDir = await getApplicationDocumentsDirectory();
      _dir = appDir.path;
    }
    return _dir!;
  }

  // ─── 缓存视频列表 ───

  /// 保存视频列表（仅扫描模式的结果）
  static Future<void> saveVideoList({
    required List<BiliVideo> videos,
    required String rootPath,
    required bool isScanMode,
    required String diagnosticInfo,
  }) async {
    final dir = await _cacheDir;
    final list = videos.map((v) => {
      'cid': v.cid,
      'folderPath': v.folderPath,
      'avid': v.avid,
      'avidFolderName': v.avidFolderName,
      'bvid': v.bvid,
      'title': v.title,
      'ownerName': v.ownerName,
      'durationMs': v.durationMs,
      'qualityTag': v.qualityTag,
      'qualityLabel': v.qualityLabel,
      'width': v.width,
      'height': v.height,
      'frameRate': v.frameRate,
      'coverPath': v.coverPath,
      'audioPath': v.audioPath,
      'videoPath': v.videoPath,
      'audioSize': v.audioSize,
      'videoSize': v.videoSize,
      'danmakuCount': v.danmakuCount,
      'downloadTimestamp': v.downloadTimestamp,
      'originalMediaPath': v.originalMediaPath,
      'originalSourceFolder': v.originalSourceFolder,
    }).toList();

    final data = {
      'videos': list,
      'rootPath': rootPath,
      'isScanMode': isScanMode,
      'diagnosticInfo': diagnosticInfo,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    await File('$dir/BiliVideoCache.json').writeAsString(jsonEncode(data));
  }

  /// 读取缓存的视频列表，null 表示无缓存
  static Future<Map<String, dynamic>?> loadVideoList() async {
    final dir = await _cacheDir;
    final f = File('$dir/BiliVideoCache.json');
    if (!await f.exists()) return null;
    try {
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final videoList = (data['videos'] as List).map((e) {
        final m = e as Map<String, dynamic>;
        return BiliVideo(
          cid: m['cid'] ?? '',
          folderPath: m['folderPath'] ?? '',
          avid: m['avid'] ?? '',
          avidFolderName: m['avidFolderName'] ?? '',
          bvid: m['bvid'] ?? '',
          title: m['title'] ?? '未知视频',
          ownerName: m['ownerName'] ?? '未知UP主',
          durationMs: m['durationMs'] ?? 0,
          qualityTag: m['qualityTag'] ?? 0,
          qualityLabel: m['qualityLabel'] ?? '',
          width: m['width'] ?? 0,
          height: m['height'] ?? 0,
          frameRate: (m['frameRate'] ?? 0).toDouble(),
          coverPath: m['coverPath'] ?? '',
          audioPath: m['audioPath'] ?? '',
          videoPath: m['videoPath'] ?? '',
          audioSize: m['audioSize'] ?? 0,
          videoSize: m['videoSize'] ?? 0,
          danmakuCount: m['danmakuCount'] ?? 0,
          downloadTimestamp: m['downloadTimestamp'] ?? 0,
          originalMediaPath: m['originalMediaPath'],
          originalSourceFolder: m['originalSourceFolder'],
        );
      }).toList();
      return {
        'videos': videoList,
        'rootPath': data['rootPath'] ?? '',
        'isScanMode': data['isScanMode'] ?? false,
        'diagnosticInfo': data['diagnosticInfo'] ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// 清空缓存
  static Future<void> clearCache() async {
    final dir = await _cacheDir;
    final f = File('$dir/BiliVideoCache.json');
    if (await f.exists()) await f.delete();
  }
}
