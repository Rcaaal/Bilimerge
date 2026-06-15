import "package:flutter/material.dart";

class WelcomeView extends StatelessWidget {
  final VoidCallback onLoadBiliCache;
  final VoidCallback onOpenExportFolder;

  const WelcomeView({
    super.key,
    required this.onLoadBiliCache,
    required this.onOpenExportFolder,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_special, size: 80, color: Colors.indigo[200]),
          const SizedBox(height: 24),
          const Text("选择 B 站缓存根目录",
              style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          Text("目录应包含多个 avid 编号文件夹",
              style: TextStyle(fontSize: 13, color: Colors.grey[400])),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onLoadBiliCache,
            icon: const Icon(Icons.cloud_download),
            label: const Text("加载B站缓存"),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onOpenExportFolder,
            icon: const Icon(Icons.download),
            label: const Text("打开导出目录"),
          ),
        ],
      ),
    );
  }
}
