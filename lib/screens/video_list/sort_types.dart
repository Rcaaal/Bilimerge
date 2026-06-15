import "package:flutter/material.dart";

String fmtSize(int bytes) {
  if (bytes < 1024) return "$bytes B";
  if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
  if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
}

enum SortField { size, date, owner, exported }

enum SortOrder { asc, desc }

extension SortFieldExt on SortField {
  String get label {
    switch (this) {
      case SortField.size:
        return "大小";
      case SortField.date:
        return "时间";
      case SortField.owner:
        return "UP主";
      case SortField.exported:
        return "导出状态";
    }
  }

  IconData get icon {
    switch (this) {
      case SortField.size:
        return Icons.storage;
      case SortField.date:
        return Icons.schedule;
      case SortField.owner:
        return Icons.person;
      case SortField.exported:
        return Icons.checklist;
    }
  }
}
