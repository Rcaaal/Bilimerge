import "package:flutter/material.dart";
import "package:open_file/open_file.dart";
import "../models/export_record.dart";
import "../services/delete_service.dart";
import "../services/export_service.dart";

class ExportHistoryScreen extends StatefulWidget {
  const ExportHistoryScreen({super.key});
  @override
  State<ExportHistoryScreen> createState() => _ExportHistoryScreenState();
}

class _ExportHistoryScreenState extends State<ExportHistoryScreen> {
  List<ExportRecord> _records = [];
  bool _loading = true;
  bool _selectMode = false;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _records = await ExportService.getHistory();
    if (mounted) setState(() => _loading = false);
  }

  void _exitSelect() => setState(() { _selectMode = false; _selected.clear(); });

  List<ExportRecord> get _selectedRecords => _selected.map((i) => _records[i]).toList();

  Future<void> _deleteOriginals() async {
    final list = _selectedRecords.where((r) => !r.originalDeleted).toList();
    if (list.isEmpty) {
      _snack("选中的项目原文件夹已删除");
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("确认删除"),
        content: Text("删除 ${list.length} 个原始缓存文件夹？\n删除后不可恢复。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text("删除原文件夹")),
        ],
      ),
    );
    if (ok != true) return;

    // 通过 DeleteService 删除文件夹（支持 Shizuku + 诊断日志）
    int success = 0;
    for (final r in list) {
      final result = await DeleteService.deleteByPath(
        path: r.originalFolderPath,
        title: r.title,
      );
      if (result.success) success++;
      await ExportService.markOriginalDeleted(r);
    }

    _snack("已删除 $success/${list.length} 个原文件夹");
    _exitSelect();
    _load();
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? "已选 ${_selected.length} 项" : "导出历史"),
        leading: _selectMode
            ? IconButton(icon: const Icon(Icons.close), onPressed: _exitSelect)
            : null,
        actions: [
          if (!_selectMode && _records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.folder_off),
              tooltip: "管理已导出项",
              onPressed: () => setState(() => _selectMode = true),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(child: Text("还没有导出记录"))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: _records.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _records[i];
                      final sel = _selected.contains(i);
                      return InkWell(
                        onTap: () {
                          if (_selectMode) {
                            setState(() { sel ? _selected.remove(i) : _selected.add(i); });
                          } else {
                            OpenFile.open(r.filePath);
                          }
                        },
                        onLongPress: () {
                          if (!_selectMode) setState(() { _selectMode = true; _selected.add(i); });
                        },
                        child: Container(
                          color: sel ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              if (_selectMode)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked, color: sel ? Colors.indigoAccent : Colors.grey, size: 24),
                                ),
                              Icon(
                                r.originalDeleted ? Icons.cloud_off : Icons.check_circle,
                                color: r.originalDeleted ? Colors.grey : Colors.green,
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(r.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                                    const SizedBox(height: 3),
                                    Text("${r.dateFormatted} · ${r.sizeFormatted}", style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                                    if (r.originalDeleted)
                                      Text("原文件夹已删除", style: TextStyle(fontSize: 11, color: Colors.orange[400])),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
      bottomSheet: _selectMode && _selected.isNotEmpty
          ? Container(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text("已选 ${_selected.length} 项", style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600))),
                      FilledButton.icon(
                        onPressed: _selectedRecords.any((r) => !r.originalDeleted) ? _deleteOriginals : null,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text("删除原文件夹"),
                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
