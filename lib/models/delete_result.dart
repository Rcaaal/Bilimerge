/// 删除操作结果模型
///
/// 记录单次删除的成功/失败状态、释放空间、文件数等信息。
/// 用于批量删除时汇总每个视频的删除结果。
class DeleteResult {
  /// 是否成功删除
  final bool success;

  /// 被删除的文件夹路径
  final String path;

  /// 视频标题（用于日志/UI）
  final String videoTitle;

  /// 失败时的错误描述
  final String? errorMessage;

  /// 成功时删除的文件数量
  final int deletedFileCount;

  /// 成功时释放的空间（字节）
  final int freedBytes;

  const DeleteResult({
    required this.success,
    required this.path,
    this.videoTitle = "",
    this.errorMessage,
    this.deletedFileCount = 0,
    this.freedBytes = 0,
  });

  /// 格式化为人类可读的摘要
  String get summary {
    if (success) {
      final sizeMb = freedBytes > 0
          ? "${(freedBytes / 1024 / 1024).toStringAsFixed(1)} MB"
          : "未知";
      return "[成功] $videoTitle — 删除了 $deletedFileCount 个文件，释放 $sizeMb";
    }
    return "[失败] $videoTitle — ${errorMessage ?? "未知错误"}";
  }

  @override
  String toString() =>
      "DeleteResult(success: $success, path: $path, videoTitle: $videoTitle, "
      "deletedFileCount: $deletedFileCount, freedBytes: $freedBytes, "
      "errorMessage: $errorMessage)";
}
