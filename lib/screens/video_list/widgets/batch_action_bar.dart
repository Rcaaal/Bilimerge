import "package:flutter/material.dart";

class BatchActionBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback? onExport;
  final VoidCallback onDelete;

  const BatchActionBar({
    super.key,
    required this.selectedCount,
    required this.onExport,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      color: theme.colorScheme.primaryContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  "已选 $selectedCount 项",
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: onExport,
                icon: const Icon(Icons.file_download, size: 18),
                label: const Text("导出"),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text("删除"),
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
