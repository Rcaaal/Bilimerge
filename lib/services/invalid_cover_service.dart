/// 失效视频封面记录服务
///
/// 持久化记录经 B 站 API 确认已失效（下架/删除）的视频，
/// 避免每次启动都重复下载封面。
import "dart:convert";
import "dart:io";
import "package:path_provider/path_provider.dart";

class InvalidVideoRecord {
  final String bvid;
  final String title;
  final String ownerName;
  final String avidFolderName; // 用于构建盖路径 / 封面占位
  final int detectedAt; // 失效检测时间戳（毫秒）

  const InvalidVideoRecord({
    required this.bvid,
    required this.title,
    required this.ownerName,
    required this.avidFolderName,
    required this.detectedAt,
  });

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'title': title,
        'ownerName': ownerName,
        'avidFolderName': avidFolderName,
        'detectedAt': detectedAt,
      };

  factory InvalidVideoRecord.fromJson(Map<String, dynamic> json) =>
      InvalidVideoRecord(
        bvid: json['bvid'] ?? '',
        title: json['title'] ?? '未知视频',
        ownerName: json['ownerName'] ?? '未知UP主',
        avidFolderName: json['avidFolderName'] ?? '',
        detectedAt: json['detectedAt'] ?? 0,
      );
}

class InvalidCoverService {
  static List<InvalidVideoRecord> _records = [];
  static bool _loaded = false;
  static String? _dir;

  static Future<String> get _storageDir async {
    if (_dir == null) {
      final appDir = await getApplicationDocumentsDirectory();
      _dir = appDir.path;
    }
    return _dir!;
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _storageDir;
      final f = File('$dir/BiliInvalidCovers.json');
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _records = list
            .map((e) =>
                InvalidVideoRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      _records = [];
    }
  }

  static Future<void> _save() async {
    final dir = await _storageDir;
    await File('$dir/BiliInvalidCovers.json')
        .writeAsString(jsonEncode(_records.map((e) => e.toJson()).toList()));
  }

  /// 检查 BVID 是否已被标记为失效
  static Future<bool> isInvalid(String bvid) async {
    await _ensureLoaded();
    return _records.any((r) => r.bvid == bvid);
  }

  /// 标记一个视频为失效
  static Future<void> markInvalid({
    required String bvid,
    required String title,
    required String ownerName,
    required String avidFolderName,
  }) async {
    await _ensureLoaded();
    if (_records.any((r) => r.bvid == bvid)) return; // 已存在
    _records.add(InvalidVideoRecord(
      bvid: bvid,
      title: title,
      ownerName: ownerName,
      avidFolderName: avidFolderName,
      detectedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await _save();
  }

  /// 获取所有失效视频记录
  static Future<List<InvalidVideoRecord>> getAll() async {
    await _ensureLoaded();
    return List.unmodifiable(_records);
  }

  /// 从失效列表中移除（手动重下时调用）
  static Future<void> remove(String bvid) async {
    await _ensureLoaded();
    _records.removeWhere((r) => r.bvid == bvid);
    await _save();
  }

  /// 清空失效记录
  static Future<void> clear() async {
    _records = [];
    await _save();
  }
}
