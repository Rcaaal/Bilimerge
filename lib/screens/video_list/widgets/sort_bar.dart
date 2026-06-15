import "package:flutter/material.dart";
import "../sort_types.dart";

class SortBar extends StatelessWidget {
  final SortField sortField;
  final SortOrder sortOrder;
  final void Function(SortField) onToggle;

  const SortBar({
    super.key,
    required this.sortField,
    required this.sortOrder,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<SortField>(
      tooltip: "排序方式",
      onSelected: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(sortField.icon,
              size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(sortField.label,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.primary)),
          const SizedBox(width: 2),
          Icon(
            sortOrder == SortOrder.desc
                ? Icons.arrow_downward
                : Icons.arrow_upward,
            size: 12,
            color: theme.colorScheme.primary,
          ),
        ]),
      ),
      itemBuilder: (ctx) => SortField.values.map((f) {
        final selected = f == sortField;
        return PopupMenuItem<SortField>(
          value: f,
          child: Row(children: [
            Icon(f.icon,
                size: 20,
                color: selected ? theme.colorScheme.primary : null),
            const SizedBox(width: 12),
            Text(f.label,
                style: TextStyle(
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal)),
            const Spacer(),
            if (selected)
              Icon(
                sortOrder == SortOrder.desc
                    ? Icons.arrow_downward
                    : Icons.arrow_upward,
                size: 16,
                color: theme.colorScheme.primary,
              ),
          ]),
        );
      }).toList(),
    );
  }
}
