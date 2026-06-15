import "package:flutter/material.dart";

import "../../../models/bili_video.dart";
import "../../../services/bili_cover_service.dart";
import "../../cover_download_screen.dart";

class CoverDownloadIndicator extends StatelessWidget {
  final List<BiliVideo> videos;
  final String coverDir;
  final void Function(BiliVideo) onPlay;
  final void Function(BiliVideo) onExport;
  final VoidCallback onCoverRefreshed;

  const CoverDownloadIndicator({
    super.key,
    required this.videos,
    required this.coverDir,
    required this.onPlay,
    required this.onExport,
    required this.onCoverRefreshed,
  });

  @override
  Widget build(BuildContext context) {
    final s = BiliCoverService.status;
    if (!s.isRunning && s.total == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final progress = s.progress ?? 1.0;
    final label =
        s.isRunning ? "封面 ${s.completed + s.failed}/${s.total}" : "封面完成";
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CoverDownloadScreen(
              videos: videos,
              coversDir: coverDir,
              onPlay: onPlay,
              onExport: onExport,
              onCoverRefreshed: onCoverRefreshed,
            ),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withOpacity(0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2,
                color: s.isRunning
                    ? theme.colorScheme.primary
                    : Colors.green,
              ),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onPrimaryContainer)),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right,
                size: 14,
                color: theme.colorScheme.onPrimaryContainer
                    .withOpacity(0.5)),
          ]),
        ),
      ),
    );
  }
}
