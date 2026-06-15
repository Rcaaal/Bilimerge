import "dart:async";

import "package:flutter/material.dart";

import "../../../models/bili_video.dart";
import "../../../services/delete_service.dart";
import "../../../services/settings_service.dart";
import "../../../services/shell_copy_service.dart";
import "../sort_types.dart";
// ─────────────────────────────────────────────────────────────
// 导出确认
// ─────────────────────────────────────────────────────────────

/// 导出确认对话框，返回 true=确认
Future<bool> showExportConfirmDialog(
    BuildContext context, List<BiliVideo> list) async {
  int totalSize = 0;
  final buf = StringBuffer();
  for (final v in list) {
    totalSize += v.totalBytes;
    buf.writeln("  ${v.title} (${v.ownerName}) - ${v.sizeFormatted}");
  }
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text("确认导出 ${list.length} 个视频"),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("合计: ${list.length} 个, 共 ${fmtSize(totalSize)}"),
                const Divider(),
                Text(buf.toString(), style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("取消")),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("确认导出")),
          ],
        ),
      ) ??
      false;
}

// ─────────────────────────────────────────────────────────────
// 删除确认
// ─────────────────────────────────────────────────────────────

/// 删除确认对话框，返回 true=确认
Future<bool> showDeleteConfirmDialog(
    BuildContext context, List<BiliVideo> list) async {
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text("确认删除 ${list.length} 个文件夹"),
          content: Text(
              "将永久删除原始缓存文件夹:\n${list.map((v) => "  ${v.title}").join("\n")}\n\n不可撤销!"),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("取消")),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text("确认删除"),
            ),
          ],
        ),
      ) ??
      false;
}

// ─────────────────────────────────────────────────────────────
// 导出目录选择
// ─────────────────────────────────────────────────────────────

/// 导出目录选择对话框
/// 返回 "cancel"=取消, "pick"=指定文件夹, "default"=默认路径
Future<String> showExportDirChoiceDialog(
    BuildContext context, List<BiliVideo> list) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text("导出 ${list.length} 个视频"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              "合计: ${list.length} 个, 共 ${fmtSize(list.fold(0, (s, v) => s + v.totalBytes))}"),
          const SizedBox(height: 12),
          const Text("选择导出目录方式：", style: TextStyle(fontSize: 13)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, "cancel"),
            child: const Text("取消")),
        OutlinedButton(
            onPressed: () => Navigator.pop(ctx, "pick"),
            child: const Text("指定文件夹")),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, "default"),
            child: const Text("确定")),
      ],
    ),
  );
  return choice ?? "cancel";
}

// ─────────────────────────────────────────────────────────────
// Shizuku 模式选择
// ─────────────────────────────────────────────────────────────

/// Shizuku 模式选择对话框
/// 返回 "full"=全量复制, "scan"=仅扫描, null=取消
Future<String?> showShizukuModeChoiceDialog(BuildContext context) async {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text("选择读取方式"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _modeOption(ctx, "full", Icons.copy_all, "全量复制",
              "复制全部缓存到临时目录\n导出快，但首次需等待"),
          const SizedBox(height: 8),
          _modeOption(ctx, "scan", Icons.fast_forward, "仅扫描（推荐）",
              "只读取视频列表和封面\n首次秒开，导出时逐个复制"),
        ],
      ),
    ),
  );
}

Widget _modeOption(BuildContext ctx, String value, IconData icon,
    String title, String desc) {
  return SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: () => Navigator.pop(ctx, value),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(children: [
        Icon(icon, size: 32, color: Colors.indigo[400]),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(desc,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey[500])),
            ],
          ),
        ),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────
// 复制进度指示（简单状态）
// ─────────────────────────────────────────────────────────────

/// 显示复制进度对话框（不可取消），执行 copyFn 后自动关闭
/// 返回 true=复制成功
Future<bool> showCopyProgressDialog(
    BuildContext context, Future<bool> Function() copyFn) async {
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Row(children: [
        SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        const Text("正在复制缓存"),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("正在通过 Shizuku 复制 B 站缓存文件...",
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Text("首次复制可能需要几十秒到几分钟",
                style: TextStyle(
                    fontSize: 12, color: Colors.grey[500])),
          ],
        ),
      ),
    ),
  ));

  await Future.delayed(const Duration(milliseconds: 100));

  bool result;
  try {
    result = await copyFn();
  } catch (e) {
    result = false;
  }

  if (context.mounted) Navigator.of(context).pop();
  return result;
}

// ─────────────────────────────────────────────────────────────
// Shizuku 权限请求引导
// ─────────────────────────────────────────────────────────────

/// Shizuku 权限引导对话框，返回 true=用户点击了「授权」
Future<bool> showShizukuPermissionDialog(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.security, color: Colors.indigo),
            SizedBox(width: 8),
            Text("Shizuku 授权"),
          ]),
          content: const SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    "BiliMerge 需要通过 Shizuku 来访问 Android/data 目录。"),
                SizedBox(height: 12),
                Text("点击「授权」后，系统会弹出授权对话框，请选择允许。",
                    style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("取消")),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("授权")),
          ],
        ),
      ) ??
      false;
}

// ─────────────────────────────────────────────────────────────
// Shizuku 启动引导
// ─────────────────────────────────────────────────────────────

/// Shizuku 服务未启动时的引导对话框，返回 true=用户点了「已启动，重试」
Future<bool> showShizukuStartupGuideDialog(BuildContext context) async {
  return (await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(children: [
            Icon(Icons.power_settings_new, color: Colors.orange),
            const SizedBox(width: 8),
            const Text("Shizuku 未启动"),
          ]),
          content: const SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Shizuku 已安装但服务未运行。"),
                SizedBox(height: 12),
                Text("请按以下步骤操作：",
                    style: TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(height: 8),
                Text(
                  "1. 打开 Shizuku 应用\n"
                  "2. 点击「启动」\n"
                  "  • 有 root → 直接点「启动」\n"
                  "  • 无 root → 点击「配对」→ 通知栏输入配对码\n"
                  "3. 返回本应用，点「已启动」重试",
                  style: TextStyle(fontSize: 13, height: 1.6),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("算了，用其他方式")),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("已启动，重试")),
          ],
        ),
      )) ??
      false;
}

// ─────────────────────────────────────────────────────────────
// MT 管理器引导
// ─────────────────────────────────────────────────────────────

/// MT 管理器引导对话框
/// 返回 "pick"=已复制完成选择目录, null=取消
Future<String?> showMTManagerGuideDialog(
    BuildContext context, bool mtLaunched) async {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text("需要手动复制"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(
            children: [
              const TextSpan(text: "由于 "),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text("Android 16 限制",
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange[800])),
                ),
              ),
              const TextSpan(
                  text:
                      "，应用无法直接访问 Android/data。\n\n"),
              TextSpan(
                text: "💡 推荐安装 Shizuku（无需 root），\n"
                    "   重启应用后可自动访问缓存。",
                style: TextStyle(
                    fontSize: 12, color: Colors.indigo),
              ),
              const TextSpan(
                  text:
                      "\n\n或者使用 MT管理器 手动复制："),
            ],
          )),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "1. 打开 MT管理器\n"
              "2. 进入 /Android/data/tv.danmaku.bili/download\n"
              "3. 长按整个 download 文件夹 → 复制\n"
              "4. 进入 /Download/bili_cache → 粘贴\n"
              "5. 返回本应用，点「已复制完成」",
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
          const SizedBox(height: 12),
          if (mtLaunched)
            Text("已尝试打开 MT管理器",
                style: TextStyle(
                    fontSize: 12, color: Colors.green[600])),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text("取消")),
        if (!mtLaunched)
          TextButton(
            onPressed: () async {
              await ShellCopyService.launchMTManager();
            },
            child: const Text("打开MT管理器"),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, "pick"),
          child: const Text("已复制完成，选择目录"),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────
// 删除详情确认（输入 y）
// ─────────────────────────────────────────────────────────────

/// 删除确认对话框，展示文件夹详情并要求输入 y 确认
///
/// 包含：
///   - 视频标题 / UP主
///   - 文件夹路径（截断显示）
///   - 文件数量 / 总大小
///   - APK 警告（如路径包含 APK）
///   - 输入框：必须输入 "y" 后确认按钮才可用
///
/// 返回 true = 确认删除
Future<bool> showDeleteDetailDialog(
  BuildContext context,
  BiliVideo video,
  FolderInfo info,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Row(
                children: [
                  Icon(
                    info.containsApk ? Icons.warning_amber : Icons.delete_outline,
                    color: info.containsApk ? Colors.red : null,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  const Text("确认删除源文件"),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 视频信息
                    _detailRow("标题", video.title),
                    _detailRow("UP主", video.ownerName),
                    const SizedBox(height: 8),
                    // 路径
                    const Text("文件夹路径：",
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: SelectableText(
                        info.path,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 文件信息
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        info.summary,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.indigo[700],
                        ),
                      ),
                    ),
                    // 不可撤销警告
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.error_outline, size: 16, color: Colors.orange[700]),
                        const SizedBox(width: 6),
                        Text(
                          "此操作不可撤销！",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange[800],
                          ),
                        ),
                      ],
                    ),
                    // APK 警告
                    if (info.containsApk)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.block, size: 18, color: Colors.red),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                "⚠️ 检测到 APK 文件，此文件夹无法删除！",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text("取消"),
                ),
                FilledButton(
                  onPressed: info.containsApk ? null : () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    disabledBackgroundColor: Colors.grey[300],
                  ),
                  child: Text(info.containsApk ? "无法删除" : "确认删除"),
                ),
              ],
            ),
      ) ??
      false;
}

Widget _detailRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Text("$label：",
              style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        ),
        Expanded(
          child: Text(value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────
// 批量删除确认
// ─────────────────────────────────────────────────────────────

/// 批量删除确认对话框，展示列表
///
/// [videos] 为待删除列表。
/// 返回 true = 确认删除
Future<bool> showBatchDeleteConfirmDialog(
  BuildContext context,
  List<BiliVideo> videos,
) async {
  final totalSize = videos.fold<int>(0, (s, v) => s + v.totalBytes);
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.delete_outline, size: 24),
                  SizedBox(width: 8),
                  Text("确认批量删除"),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "将删除 ${videos.length} 个文件夹：",
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    // 视频列表
                    Container(
                      constraints: const BoxConstraints(maxHeight: 200),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: videos.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final v = videos[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            child: Row(
                              children: [
                                Text(
                                  "${i + 1}.",
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey[500]),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    v.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  v.sizeFormatted,
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 合计
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "合计: ${videos.length} 个, 共 ${fmtSize(totalSize)}",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.indigo[700],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 不可撤销警告
                    Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 16, color: Colors.orange[700]),
                        const SizedBox(width: 6),
                        Text(
                          "此操作不可撤销！",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange[800],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text("取消"),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                  ),
                  child: const Text("确认删除"),
                ),
              ],
            ),
      ) ??
      false;
}

// ─────────────────────────────────────────────────────────────
// 手动删除指引（Shizuku 无法自动删除时调用）
// ─────────────────────────────────────────────────────────────

/// 手动删除指引对话框
///
/// 自动复制路径到剪贴板，引导用户在文件管理器中手动删除。
/// 返回 true = 用户确认已手动删除，false = 放弃删除
Future<bool> showManualDeleteGuideDialog(
  BuildContext context, {
  required String path,
  required String videoTitle,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.orange, size: 24),
              SizedBox(width: 8),
              Expanded(child: Text("需要手动删除")),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("$videoTitle 的源文件夹路径已复制到剪贴板。"),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    path,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.indigo.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    "操作步骤：\n"
                    "1. 路径已复制到剪贴板\n"
                    "2. 手动打开 MT 管理器或文件管理器\n"
                    "3. 在顶部/底部路径栏粘贴路径\n"
                    "4. 进入后长按 avid 文件夹 → 删除\n"
                    "5. 返回本应用 → 点「已删除，确认」",
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("取消"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("已删除，确认"),
            ),
          ],
        ),
      ) ??
      false;
}