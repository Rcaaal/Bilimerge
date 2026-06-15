/// 封面下载失败记录服务（网络错误）
///
/// 持久化记录因网络错误导致封面下载失败的视频，
/// 避免每次启动重复下载。仅当用户手动点击"重新下载"才会重试。
import "dart:convert";
import "dart:io";
import "package:path_provider/path_provider.dart";

class FailedCoverRecord {
  final String bvid;
  final String title;
  final String ownerName;
  final String avidFolderName;
  final int detectedAt;

  const FailedCoverRecord({
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

  factory FailedCoverRecord.fromJson(Map<String, dynamic> json) =>
      FailedCoverRecord(
        bvid: json['bvid'] ?? '',
        title: json['title'] ?? '未知视频',
        ownerName: json['ownerName'] ?? '未知UP主',
        avidFolderName: json['avidFolderName'] ?? '',
        detectedAt: json['detectedAt'] ?? 0,
      );
}

class FailedCoverService {
  static List<FailedCoverRecord> _records = [];
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
      final f = File('$dir/BiliFailedCovers.json');
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _records = list
            .map((e) => FailedCoverRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      _records = [];
    }
  }

  static Future<void> _save() async {
    final dir = await _storageDir;
    await File('$dir/BiliFailedCovers.json')
        .writeAsString(jsonEncode(_records.map((e) => e.toJson()).toList()));
  }

  /// 检查 BVID 是否在下载失败列表中
  static Future<bool> isFailed(String bvid) async {
    await _ensureLoaded();
    return _records.any((r) => r.bvid == bvid);
  }

  /// 标记一个视频为下载失败（网络错误）
  static Future<void> markFailed({
    required String bvid,
    required String title,
    required String ownerName,
    required String avidFolderName,
  }) async {
    await _ensureLoaded();
    if (_records.any((r) => r.bvid == bvid)) return;
    _records.add(FailedCoverRecord(
      bvid: bvid,
      title: title,
      ownerName: ownerName,
      avidFolderName: avidFolderName,
      detectedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await _save();
  }

  /// 从失败列表中移除（重下成功后调用）
  static Future<void> remove(String bvid) async {
    await _ensureLoaded();
    _records.removeWhere((r) => r.bvid == bvid);
    await _save();
  }

  /// 获取所有下载失败记录
  static Future<List<FailedCoverRecord>> getAll() async {
    await _ensureLoaded();
    return List.unmodifiable(_records);
  }

  /// 清空
  static Future<void> clear() async {
    _records = [];
    await _save();
  }
}
