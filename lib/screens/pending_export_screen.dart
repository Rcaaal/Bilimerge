/// 待导出队列页面
///
/// 显示所有已加入待导出队列的视频。
/// 每个视频右侧只有"移出队列"按钮。
/// 右上角：批量导出（直接用默认路径，不弹选择对话框）| 清空队列 | 返回
/// 队列仅在本次会话有效，重启清空。
import "package:flutter/material.dart";
import "../controllers/video_list_controller.dart";
import "../models/bili_video.dart";

class PendingExportScreen extends StatefulWidget {
  final VideoListController controller;

  const PendingExportScreen({
    super.key,
    required this.controller,
  });

  @override
  State<PendingExportScreen> createState() => _PendingExportScreenState();
}

class _PendingExportScreenState extends State<PendingExportScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.controller.pendingExportVideos;
    return Scaffold(
      appBar: AppBar(
        title: Text("待导出队列 (${list.length})"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: "返回",
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (list.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: "清空队列",
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text("清空队列"),
                    content: const Text("确定清空待导出队列？"),
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
                  widget.controller.clearPendingExports();
                  Navigator.pop(context);
                }
              },
            ),
          if (list.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.file_download),
              tooltip: "批量导出",
              onPressed: () async {
                final videos = widget.controller.pendingExportVideos.toList();
                widget.controller.clearPendingExports();
                if (!context.mounted) return;
                Navigator.pop(context, videos);
              },
            ),
        ],
      ),
      body: list.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.playlist_add, size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 12),
                  Text("队列为空", style: TextStyle(fontSize: 16, color: Colors.grey[500])),
                  const SizedBox(height: 4),
                  Text("点击视频旁的 + 号加入队列", style: TextStyle(fontSize: 13, color: Colors.grey[400])),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final v = list[i];
                return Card(
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 60,
                        height: 42,
                        child: Container(color: Colors.indigo.withOpacity(0.08), child: Icon(Icons.videocam, color: Colors.indigo[300], size: 24)),
                      ),
                    ),
                    title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                      "${v.ownerName} · ${v.sizeFormatted} · ${v.durationFormatted}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 22),
                      tooltip: "移出队列",
                      onPressed: () {
                        widget.controller.togglePendingExport(v);
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}
