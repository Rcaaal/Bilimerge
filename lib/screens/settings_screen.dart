/// 设置页面
/// 缓存管理 / 关于
import "dart:io";
import "package:flutter/material.dart";
import "../services/settings_service.dart";
import "../services/video_cache_service.dart";

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onCacheCleared;
  final VoidCallback? onPickDir;
  const SettingsScreen({super.key, this.onCacheCleared, this.onPickDir});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _checkingCache = true;
  bool _hasCache = false;
  String? _cacheInfo;
  String? _coverCacheSize;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cache = await VideoCacheService.loadVideoList();

    String? coverSize;
    try {
      final coversDir = await SettingsService.getCoversDir();
      final dir = Directory(coversDir);
      if (await dir.exists()) {
        int totalSize = 0;
        int fileCount = 0;
        await for (final f in dir.list(recursive: true)) {
          if (f is File) {
            totalSize += await f.length();
            fileCount++;
          }
        }
        coverSize = "${_fmtSize(totalSize)} ($fileCount 个文件)";
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _hasCache = cache != null;
        _cacheInfo = cache != null
            ? "${(cache['videos'] as List).length} 个视频"
            : "无缓存";
        _coverCacheSize = coverSize ?? "未知";
        _checkingCache = false;
      });
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("清空视频缓存"),
        content: const Text("清空后视频列表将回到初始页面，需重新扫描。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("清空"),
          ),
        ],
      ),
    );
    if (ok == true) {
      await VideoCacheService.clearCache().then((_) async {
        try {
          final coversDir = await SettingsService.getCoversDir();
          await Directory(coversDir).delete(recursive: true);
          await Directory(coversDir).create(recursive: true);
        } catch (_) {}
      });
      widget.onCacheCleared?.call();
      _snack("缓存已清空");
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _clearCoverCache() async {
    try {
      final coversDir = await SettingsService.getCoversDir();
      await Directory(coversDir).delete(recursive: true);
      await Directory(coversDir).create(recursive: true);
      _snack("封面缓存已清除（重新扫描可恢复）");
      _load();
    } catch (_) {}
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("设置")),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ─── 缓存管理 ───
          _sectionHeader("缓存管理"),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text("视频列表缓存"),
                subtitle: Text(_checkingCache ? "检查中..." : _cacheInfo!,
                    style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                trailing: _checkingCache
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : (_hasCache
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            tooltip: "清空缓存",
                            onPressed: _clearCache,
                          )
                        : const Icon(Icons.check, color: Colors.green)),
              ),
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text("封面缓存"),
                subtitle: Text(_coverCacheSize ?? "计算中...",
                    style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: "刷新封面缓存",
                  onPressed: _clearCoverCache,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // ─── 手动选择目录 ───
          _sectionHeader("缓存目录"),
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text("手动选择B站缓存"),
              subtitle: Text("当自动缓存读取不可用时，手动选择缓存文件夹",
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              onTap: () {
                widget.onPickDir?.call();
                if (widget.onPickDir != null && Navigator.of(context).canPop()) {
                  Navigator.pop(context);
                }
              },
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
          const SizedBox(height: 20),

          // ─── 导出目录 ───
          _sectionHeader("导出目录"),
          Card(
            child: ListTile(
              leading: const Icon(Icons.download),
              title: const Text("导出位置"),
              subtitle: const Text("/storage/emulated/0/Download/Bilimerge",
                  style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(height: 20),

          // ─── 关于 ───
          _sectionHeader("关于"),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text("BiliMerge v2.0.0"),
              subtitle: Text("Bilibili 缓存音视频合并工具",
                  style: TextStyle(fontSize: 13, color: Colors.grey[500])),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[600])),
    );
  }
}
