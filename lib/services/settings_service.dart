/// 持久化设置服务
/// 存储导出路径、最后选择的目录等用户偏好
import "dart:convert";
import "dart:io";
import "package:path_provider/path_provider.dart";

class SettingsService {
  static Map<String, dynamic> _settings = {};
  static bool _loaded = false;
  static String? _dir;

  static Future<String> get _settingsDir async {
    if (_dir == null) {
      final appDir = await getApplicationDocumentsDirectory();
      _dir = appDir.path;
    }
    return _dir!;
  }

  static String get _filePath => '$_settingsDir/BiliMergeSettings.json';

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _settingsDir;
      final f = File('$dir/BiliMergeSettings.json');
      if (await f.exists()) {
        _settings = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      _settings = {};
    }
  }

  static Future<void> _save() async {
    final dir = await _settingsDir;
    await File('$dir/BiliMergeSettings.json').writeAsString(jsonEncode(_settings));
  }

  // ─── 导出默认路径 ───

  static Future<String?> getDefaultExportPath() async {
    await _ensureLoaded();
    return _settings['defaultExportPath'] as String?;
  }

  static Future<void> setDefaultExportPath(String path) async {
    await _ensureLoaded();
    _settings['defaultExportPath'] = path;
    await _save();
  }

  // ─── 上次选择的导出目录 ───

  static Future<String?> getLastExportPath() async {
    await _ensureLoaded();
    return _settings['lastExportPath'] as String?;
  }

  static Future<void> setLastExportPath(String path) async {
    await _ensureLoaded();
    _settings['lastExportPath'] = path;
    await _save();
  }

  // ─── 封面存储路径（documents 下，不随临时清理消失） ───

  static Future<String> getCoversDir() async {
    final dir = await _settingsDir;
    final covers = Directory('$dir/BiliCovers');
    if (!await covers.exists()) await covers.create(recursive: true);
    return covers.path;
  }

  // ─── 手动删除跳转 App 命令 ───

  /// 获取手动删除时跳转文件管理器的命令模板
  /// 默认值: "am start -a android.intent.action.VIEW -d 'file://{path}'"（MT 管理器）
  /// {path} 会在运行时被替换为实际路径
  static Future<String> getDeleteAppCommand() async {
    await _ensureLoaded();
    return _settings['deleteAppCommand'] as String? ??
        "am start -a android.intent.action.VIEW -d 'file://{path}'";
  }

  static Future<void> setDeleteAppCommand(String command) async {
    await _ensureLoaded();
    _settings['deleteAppCommand'] = command;
    await _save();
  }

  /// 获取手动删除跳转 App 的显示名称
  static Future<String> getDeleteAppLabel() async {
    await _ensureLoaded();
    return _settings['deleteAppLabel'] as String? ?? "MT 管理器";
  }

  static Future<void> setDeleteAppLabel(String label) async {
    await _ensureLoaded();
    _settings['deleteAppLabel'] = label;
    await _save();
  }
}
