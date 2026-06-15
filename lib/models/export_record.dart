/// 导出记录模型
class ExportRecord {
  final String fileName;
  final String filePath;           // 导出后的文件路径
  final String originalFolderPath; // 原始缓存文件夹路径
  final int fileSize;
  final int exportTimestamp;
  final String title;
  final String ownerName;
  final String avid;
  final bool originalDeleted;      // 是否已删
  final String cid;                // 分P标识（用于去重键）

  ExportRecord({
    required this.fileName,
    required this.filePath,
    required this.originalFolderPath,
    required this.fileSize,
    required this.exportTimestamp,
    required this.title,
    required this.ownerName,
    required this.avid,
    this.originalDeleted = false,
    this.cid = "",
  });

  DateTime get exportDate => DateTime.fromMillisecondsSinceEpoch(exportTimestamp * 1000);
  String get dateFormatted {
    final d = exportDate;
    return "${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")} ${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
  }

  String get sizeFormatted {
    if (fileSize < 1024) return "$fileSize B";
    if (fileSize < 1024 * 1024) return "${(fileSize / 1024).toStringAsFixed(1)} KB";
    if (fileSize < 1024 * 1024 * 1024) return "${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB";
    return "${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }

  Map<String, dynamic> toJson() => {
        "fileName": fileName,
        "filePath": filePath,
        "originalFolderPath": originalFolderPath,
        "fileSize": fileSize,
        "exportTimestamp": exportTimestamp,
        "title": title,
        "ownerName": ownerName,
        "avid": avid,
        "originalDeleted": originalDeleted,
        "cid": cid,
      };

  factory ExportRecord.fromJson(Map<String, dynamic> json) => ExportRecord(
        fileName: json["fileName"] ?? "",
        filePath: json["filePath"] ?? "",
        originalFolderPath: json["originalFolderPath"] ?? "",
        fileSize: json["fileSize"] ?? 0,
        exportTimestamp: json["exportTimestamp"] ?? 0,
        title: json["title"] ?? "",
        ownerName: json["ownerName"] ?? "",
        avid: json["avid"] ?? "",
        originalDeleted: json["originalDeleted"] ?? false,
        cid: json["cid"] ?? "",
      );
}
