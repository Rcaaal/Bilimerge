/// 诊断日志服务
///
/// 持久化保存每次扫描的诊断信息，每条日志带时间戳。
/// 数据存储在 app documents 目录下的 BiliDiagnosticLog.json。
import "dart:convert";
import "dart:io";
import "package:path_provider/path_provider.dart";

class DiagnosticLogEntry {
  final DateTime timestamp;
  final String content;

  const DiagnosticLogEntry({
    required this.timestamp,
    required this.content,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.millisecondsSinceEpoch,
        'content': content,
      };

  factory DiagnosticLogEntry.fromJson(Map<String, dynamic> json) =>
      DiagnosticLogEntry(
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] ?? 0),
        content: json['content'] ?? '',
      );

  String get timestampFormatted {
    return "${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-"
        "${timestamp.day.toString().padLeft(2, '0')} "
        "${timestamp.hour.toString().padLeft(2, '0')}:"
        "${timestamp.minute.toString().padLeft(2, '0')}:"
        "${timestamp.second.toString().padLeft(2, '0')}";
  }
}

class DiagnosticLogService {
  static List<DiagnosticLogEntry> _entries = [];
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
      final f = File('$dir/BiliDiagnosticLog.json');
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString());
        if (data is List) {
          _entries = data
              .map((e) =>
                  DiagnosticLogEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (_) {
      _entries = [];
    }
  }

  static Future<void> _save() async {
    final dir = await _storageDir;
    await File('$dir/BiliDiagnosticLog.json')
        .writeAsString(jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }

  /// 添加一条诊断日志（自动附加时间戳）
  static Future<void> addEntry(String content) async {
    await _ensureLoaded();
    _entries.insert(
      0,
      DiagnosticLogEntry(
        timestamp: DateTime.now(),
        content: content,
      ),
    );
    await _save();
  }

  /// 获取所有诊断日志（最新在前）
  static Future<List<DiagnosticLogEntry>> getAll() async {
    await _ensureLoaded();
    return List.unmodifiable(_entries);
  }

  /// 清空所有诊断日志
  static Future<void> clear() async {
    _entries = [];
    await _save();
  }
}
