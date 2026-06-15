import "dart:io";

import "package:flutter/material.dart";

import "../../../models/bili_video.dart";

class VideoRow extends StatelessWidget {
  final BiliVideo video;
  final bool selected;
  final bool selectMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onExport;
  final String? coverDir;
  final bool exported;
  final bool pending;
  final VoidCallback? onTogglePending;
  final VoidCallback? onDelete;

  const VideoRow({
    super.key,
    required this.video,
    required this.selected,
    required this.selectMode,
    required this.onTap,
    required this.onLongPress,
    required this.onExport,
    this.coverDir,
    this.exported = false,
    this.pending = false,
    this.onTogglePending,
    this.onDelete,
  });

  Widget _buildCover(BuildContext context) {
    bool hasCover =
        video.coverPath.isNotEmpty && File(video.coverPath).existsSync();
    String? actualPath = hasCover ? video.coverPath : null;

    if (!hasCover &&
        video.avidFolderName.isNotEmpty &&
        coverDir != null) {
      final docCover = "$coverDir/${video.avidFolderName}/cover.jpg";
      if (File(docCover).existsSync()) {
        hasCover = true;
        actualPath = docCover;
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 80,
        height: 56,
        child: hasCover && actualPath != null
            ? Image.file(
                File(actualPath),
                width: 80,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _coverPlaceholder(),
              )
            : _coverPlaceholder(),
      ),
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      color: Colors.indigo.withValues(alpha: 0.08),
      child: Center(
        child: Icon(Icons.videocam, color: Colors.indigo[300], size: 28),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (selectMode)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: selected ? Colors.indigoAccent : Colors.grey,
                    size: 22,
                  ),
                ),
              _buildCover(context),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "${video.ownerName} · ${video.sizeFormatted} · ${video.durationFormatted}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                    if (video.downloadDate != null)
                      Text(
                        "${video.downloadDateFormatted} · ${video.qualityLabel}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey[400]),
                      ),
                    if (exported)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Icon(Icons.check_circle,
                              size: 12, color: Colors.green[400]),
                          const SizedBox(width: 3),
                          Text("已导出",
                              style: TextStyle(
                                  fontSize: 10, color: Colors.green[600])),
                        ]),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  icon: const Icon(Icons.file_download, size: 18),
                  onPressed: onExport,
                  tooltip: "导出",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  splashRadius: 16,
                ),
              ),
              if (onDelete != null && !selectMode)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: Colors.red[300]),
                    onPressed: onDelete,
                    tooltip: "删除源文件",
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    splashRadius: 16,
                  ),
                ),
              if (onTogglePending != null)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: Icon(
                      pending
                          ? Icons.check_circle
                          : Icons.add_circle_outline,
                      size: 18,
                      color: pending ? Colors.green : null,
                    ),
                    onPressed: onTogglePending,
                    tooltip:
                        pending ? "移出待导出队列" : "加入待导出队列",
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    splashRadius: 16,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
