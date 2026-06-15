/// 封面下载详情页
///
/// 三个标签页：
///   [进度] — 封面下载队列的大进度环 + 实时状态
///   [失效视频] — 已确认失效的视频列表
///   [下载失败] — 网络错误失败的视频列表（可手动重下）
import "package:flutter/material.dart";
import "../models/bili_video.dart";
import "../services/bili_cover_service.dart";
import "../services/failed_cover_service.dart";
import "../services/invalid_cover_service.dart";

class CoverDownloadScreen extends StatefulWidget {
  final List<BiliVideo> videos;
  final void Function(BiliVideo) onPlay;
  final void Function(BiliVideo) onExport;
  final VoidCallback? onCoverRefreshed; // 手动重下封面成功后回调
  final String coversDir; // BiliCovers 持久目录路径

  const CoverDownloadScreen({
    super.key,
    required this.videos,
    required this.onPlay,
    required this.onExport,
    required this.coversDir,
    this.onCoverRefreshed,
  });

  @override
  State<CoverDownloadScreen> createState() => _CoverDownloadScreenState();
}

class _CoverDownloadScreenState extends State<CoverDownloadScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<MapEntry<InvalidVideoRecord, BiliVideo?>> _invalidEntries = [];
  bool _loadingInvalid = true;

  List<MapEntry<FailedCoverRecord, BiliVideo?>> _failedEntries = [];
  bool _loadingFailed = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadInvalid();
    _loadFailed();
    BiliCoverService.onProgressChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _tabController.dispose();
    BiliCoverService.onProgressChanged = null;
    super.dispose();
  }

  Future<void> _loadInvalid() async {
    final records = await InvalidCoverService.getAll();
    final entries = records.map((r) {
      final match = widget.videos.cast<BiliVideo?>().firstWhere(
          (v) => v?.avidFolderName == r.avidFolderName,
          orElse: () => null);
      return MapEntry(r, match);
    }).toList();
    if (mounted) {
      setState(() {
        _invalidEntries = entries;
        _loadingInvalid = false;
      });
    }
  }

  Future<void> _loadFailed() async {
    final records = await FailedCoverService.getAll();
    final entries = records.map((r) {
      final match = widget.videos.cast<BiliVideo?>().firstWhere(
          (v) => v?.avidFolderName == r.avidFolderName,
          orElse: () => null);
      return MapEntry(r, match);
    }).toList();
    if (mounted) {
      setState(() {
        _failedEntries = entries;
        _loadingFailed = false;
      });
    }
  }

  /// 手动重下单个封面（从失效列表）
  Future<void> _retryInvalidCover(InvalidVideoRecord record, BiliVideo? video) async {
    if (video == null) {
      _snack("该视频不在列表中，无法重试");
      return;
    }
    _snack("正在重新下载封面...");
    final ok = await BiliCoverService.retrySingle(video, widget.coversDir);
    if (ok) {
      _snack("封面下载成功");
    } else {
      _snack("封面仍不可用");
    }
    await _loadInvalid();
    await _loadFailed();
    widget.onCoverRefreshed?.call();
  }

  /// 手动重下单个封面（从失败列表）
  Future<void> _retryCover(FailedCoverRecord record, BiliVideo? video) async {
    if (video == null) {
      _snack("该视频不在列表中，无法重试");
      return;
    }
    _snack("正在重新下载封面...");
    final ok = await BiliCoverService.retrySingle(video, widget.coversDir);
    if (ok) {
      _snack("封面下载成功");
      await _loadFailed();
      _loadInvalid();
      widget.onCoverRefreshed?.call();
    } else {
      await _loadFailed();
      _loadInvalid();
      _snack("封面仍不可用（视频已失效或网络错误）");
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final s = BiliCoverService.status;
    return Scaffold(
      appBar: AppBar(
        title: const Text("封面下载"),
        actions: [
          if (s.isRunning)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: "取消下载",
              onPressed: () {
                BiliCoverService.cancel();
                setState(() {});
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            const Tab(text: "进度"),
            Tab(text: "失效 (${_invalidEntries.length})"),
            Tab(text: "失败 (${_failedEntries.length})"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildProgressTab(context, s),
          _buildInvalidTab(context),
          _buildFailedTab(context),
        ],
      ),
    );
  }

  // ── 进度标签页 ─────────────────────────────────────

  Widget _buildProgressTab(BuildContext context, CoverDownloadStatus s) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 大进度环
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 140,
                    height: 140,
                    child: CircularProgressIndicator(
                      value: s.progress,
                      strokeWidth: 10,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      color: s.isRunning
                          ? theme.colorScheme.primary
                          : Colors.green,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "${s.total > 0 ? s.completed + s.failed : 0}",
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "/ ${s.total}",
                        style:
                            TextStyle(fontSize: 14, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.isRunning
                  ? "下载中..."
                  : s.total > 0
                      ? "下载完成"
                      : "无需下载",
              style: TextStyle(
                fontSize: 15,
                color: s.isRunning ? Colors.grey[600] : Colors.green[600],
              ),
            ),
            const SizedBox(height: 32),

            // 统计卡片
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _statItem(context,
                      icon: Icons.check_circle,
                      iconColor: Colors.green,
                      label: "成功",
                      count: s.completed),
                  _divider(context),
                  _statItem(context,
                      icon: Icons.error,
                      iconColor: Colors.red,
                      label: "失败",
                      count: s.failed),
                  _divider(context),
                  _statItem(context,
                      icon: Icons.block,
                      iconColor: Colors.orange,
                      label: "失效",
                      count: s.invalidCount),
                  _divider(context),
                  _statItem(context,
                      icon: Icons.cloud_off,
                      iconColor: Colors.grey,
                      label: "跳过失败",
                      count: s.failedSkippedCount),
                  _divider(context),
                  _statItem(context,
                      icon: Icons.hourglass_empty,
                      iconColor: Colors.grey,
                      label: "待处理",
                      count: s.pending),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 当前下载项
            if (s.isRunning && s.currentTitle != null)
              Card(
                child: ListTile(
                  leading: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  title: Text(
                    s.currentTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: s.currentBvid != null
                      ? Text(s.currentBvid!,
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[500]))
                      : null,
                ),
              ),

            // 完成
            if (!s.isRunning && s.total > 0) ...[
              const SizedBox(height: 16),
              Icon(Icons.check_circle, size: 48, color: Colors.green[400]),
              const SizedBox(height: 8),
              Text(
                "封面下载完毕",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Colors.green[700],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── 失效视频标签页 ──────────────────────────────────

  Widget _buildInvalidTab(BuildContext context) {
    if (_loadingInvalid) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_invalidEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 64,
                color: Colors.green[300]),
            const SizedBox(height: 12),
            Text("没有失效视频",
                style:
                    TextStyle(fontSize: 16, color: Colors.grey[500])),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadInvalid,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _invalidEntries.length,
        itemBuilder: (_, i) {
          final entry = _invalidEntries[i];
          final record = entry.key;
          final video = entry.value;

          return Card(
            child: ListTile(
              leading: Icon(Icons.videocam_off,
                  color: Colors.orange[400], size: 24),
              title: Text(
                "${record.ownerName} - ${record.title}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                record.bvid,
                style:
                    TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
              trailing: video != null
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: "重新下载封面",
                          onPressed: () => _retryInvalidCover(record, video),
                        ),
                        IconButton(
                          icon: const Icon(Icons.play_arrow, size: 20),
                          tooltip: "播放",
                          onPressed: () => widget.onPlay(video),
                        ),
                        IconButton(
                          icon: const Icon(Icons.file_download, size: 20),
                          tooltip: "导出",
                          onPressed: () => widget.onExport(video),
                        ),
                      ],
                    )
                  : const Icon(Icons.block, size: 18, color: Colors.grey),
              onTap: video != null ? () => widget.onPlay(video) : null,
            ),
          );
        },
      ),
    );
  }

  // ── 下载失败标签页 ──────────────────────────────────

  Widget _buildFailedTab(BuildContext context) {
    if (_loadingFailed) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failedEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_done, size: 64, color: Colors.green[300]),
            const SizedBox(height: 12),
            Text("没有下载失败的视频",
                style:
                    TextStyle(fontSize: 16, color: Colors.grey[500])),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFailed,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _failedEntries.length,
        itemBuilder: (_, i) {
          final entry = _failedEntries[i];
          final record = entry.key;
          final video = entry.value;

          return Card(
            child: ListTile(
              leading:
                  Icon(Icons.error_outline, color: Colors.red[300], size: 24),
              title: Text(
                "${record.ownerName} - ${record.title}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                record.bvid,
                style:
                    TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 重新下载按钮
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: "重新下载封面",
                    onPressed: () => _retryCover(record, video),
                  ),
                  if (video != null) ...[
                    IconButton(
                      icon: const Icon(Icons.play_arrow, size: 20),
                      tooltip: "播放",
                      onPressed: () => widget.onPlay(video),
                    ),
                    IconButton(
                      icon: const Icon(Icons.file_download, size: 20),
                      tooltip: "导出",
                      onPressed: () => widget.onExport(video),
                    ),
                  ],
                ],
              ),
              onTap: video != null ? () => widget.onPlay(video) : null,
            ),
          );
        },
      ),
    );
  }

  // ── 辅助组件 ────────────────────────────────────────

  Widget _statItem(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String label,
    required int count,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(height: 4),
        Text("$count",
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label,
            style:
                TextStyle(fontSize: 10, color: Colors.grey[500])),
      ],
    );
  }

  Widget _divider(BuildContext context) {
    return Container(width: 1, height: 28, color: Colors.grey[300]);
  }
}
