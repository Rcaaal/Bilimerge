import "dart:async";
import "dart:io";
import "package:flutter/material.dart";
import "package:file_picker/file_picker.dart";
import "package:open_file/open_file.dart";
import "package:path_provider/path_provider.dart";
import "package:permission_handler/permission_handler.dart";
import "../controllers/video_list_controller.dart";
import "../models/bili_video.dart";
import "../services/delete_service.dart";
import "../services/export_service.dart";
import "../services/export_queue.dart";
import "../services/settings_service.dart";
import "../services/shell_copy_service.dart";
import "export_history_screen.dart";
import "settings_screen.dart";
import "cover_download_screen.dart";
import "diagnostic_log_screen.dart";
import "../services/diagnostic_log_service.dart";
import "pending_export_screen.dart";
import "video_list/sort_types.dart";
import "video_list/widgets/batch_action_bar.dart";
import "video_list/widgets/cover_download_indicator.dart";
import "video_list/widgets/dialogs.dart" as dialogs;
import "video_list/widgets/sort_bar.dart";
import "video_list/widgets/video_row.dart";
import "video_list/widgets/welcome_view.dart";

class VideoListScreen extends StatefulWidget {
  const VideoListScreen({super.key});
  @override
  State<VideoListScreen> createState() => _VideoListScreenState();
}

class _VideoListScreenState extends State<VideoListScreen> {
  final controller = VideoListController();

  @override
  void initState() {
    super.initState();
    controller.addListener(_onControllerChange);
    controller.init();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCrashRecovery());
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChange);
    controller.dispose();
    super.dispose();
  }

  /// 刷新已导出状态集合
  ///
  /// 扫描两个位置：
  /// 1. ExportService.getExportedKeys() — 从历史记录和默认导出目录
  /// 2. 用户设置的默认导出路径（直接检查文件系统）
  Future<void> _refreshExportedKeys() => controller.refreshExportedKeys();

  Future<void> _checkCrashRecovery() async {
    final state = await ExportQueueService.getIncompleteState();
    if (state == null || !mounted) return;
    final resume = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("发现未完成的导出"),
        content: Text("上次导出中断了\n已完成 ${state.completedCount}/${state.totalCount} 个\n\n是否恢复导出？"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("放弃")),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("恢复导出")),
        ],
      ),
    );
    if (resume == true && mounted) {
      await ExportQueueService.discardCurrentAndResume();
      _snack("已恢复导出队列");
    } else {
      await ExportQueueService.clearState();
    }
  }

  Future<void> _pickDir() async {
    if (await Permission.manageExternalStorage.isDenied) {
      final status = await Permission.manageExternalStorage.request();
      if (status.isDenied) { _snack("需要文件管理权限"); return; }
    }
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: "选择缓存根目录");
    if (dir == null) return;

    // Android 14+：如果 file_picker 返回的是 content:// URI，走 SAF 复制
    if (ShellCopyService.isSafUri(dir)) {
      _snack("正在通过 SAF 复制缓存文件...");
      final count = await ShellCopyService.copyViaSaf(dir);
      if (count > 0) {
        _snack("已复制 $count 个视频，正在扫描...");
        await _scanDirectory(await ShellCopyService.getTempPath());
      } else {
        _snack("SAF 复制失败，请尝试其他方式");
      }
      return;
    }

    await _scanDirectory(dir);
  }

  /// 打开 B 站缓存目录
  /// 策略：Shizuku → Shell (root) → MT 管理器引导
  Future<void> _openBiliCache() async {
    // 先清空旧列表，确保重新扫描不会读到已删除的残留缓存
    controller.clearVideos();
    _snack("正在准备读取B站缓存...");
    final biliPath = "/storage/emulated/0/Android/data/tv.danmaku.bili/download";

    // ─── 方案 1：Shizuku（Android 15+ 首选）───────────
    final shizukuStatus = await ShellCopyService.checkShizuku();
    if (shizukuStatus['installed'] == true) {
      if (shizukuStatus['available'] == true) {
        // Shizuku 服务正在运行
        if (shizukuStatus['hasPermission'] == true) {
          // 已授权 → 弹出模式选择
          final mode = await dialogs.showShizukuModeChoiceDialog(context);
          if (mode == null || !mounted) return;
          if (mode == 'full') {
            // 全量复制
            final ok = await dialogs.showCopyProgressDialog(context, () => ShellCopyService.copyViaShizuku(sourceDir: biliPath));
            if (ok && mounted) {
              _snack("复制完成，正在扫描...");
              await _scanDirectory(await ShellCopyService.getFullCopyPath());
              return;
            }
            if (mounted) _snack("Shizuku 复制失败，尝试其他方式");
          } else {
            // 仅扫描 — 切换时清理全量复制目录
            await ShellCopyService.cleanFullCopyTemp();
            final scanResult = await _showScanProgressDialog(biliPath);
            if (scanResult == null || !mounted) return;
            final scanResults = (scanResult['results'] as List<ShizukuScanResult>?) ?? [];
            final scanDiag = (scanResult['diagnostic'] as String?) ?? '';
            if (scanResults.isNotEmpty && mounted) {
              await controller.buildFromShizukuScan(scanResults, await ShellCopyService.getTempPath(), scanDiag);
              return;
            }
            if (mounted) {
              setState(() {});
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("扫描诊断"),
                  content: SingleChildScrollView(
                    child: SelectableText(scanDiag, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
                  actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭"))],
                ),
              );
            }
          }
        } else {
          // 未授权 → 请求权限
          final granted = await dialogs.showShizukuPermissionDialog(context);
          if (granted == true && mounted) {
            // 请求 Shizuku 权限
            _snack("正在请求 Shizuku 授权...");
            final permOk = await ShellCopyService.requestShizukuPermission();
            if (permOk) {
              _snack("Shizuku 授权成功");
              // 授权成功后，走全量复制（不再纠缠用户选模式）
              final ok = await dialogs.showCopyProgressDialog(
                  context, () => ShellCopyService.copyViaShizuku(sourceDir: biliPath));
              if (ok && mounted) {
                _snack("复制完成，正在扫描...");
                await _scanDirectory(await ShellCopyService.getFullCopyPath());
                return;
              }
              if (mounted) _snack("Shizuku 复制失败，尝试其他方式");
            } else {
              _snack("Shizuku 授权失败，请确保已安装 Shizuku 并重试");
            }
          }
        }
      } else {
        // Shizuku 已安装但服务未启动 → 显示启动引导
        final shouldRetry = await dialogs.showShizukuStartupGuideDialog(context);
        if (shouldRetry && mounted) {
          final retryStatus = await ShellCopyService.checkShizuku();
          if (retryStatus['available'] == true && retryStatus['hasPermission'] == true && mounted) {
            // 重新检查后已就绪 → 弹出模式选择
            final mode = await dialogs.showShizukuModeChoiceDialog(context);
            if (mode == 'full' && mounted) {
              final ok = await dialogs.showCopyProgressDialog(context, () => ShellCopyService.copyViaShizuku(sourceDir: biliPath));
              if (ok && mounted) {
                await _scanDirectory(await ShellCopyService.getFullCopyPath());
                return;
              }
            } else if (mode == 'scan' && mounted) {
              // 切换仅扫描 → 清理全量复制目录
              await ShellCopyService.cleanFullCopyTemp();
              final scanResult = await _showScanProgressDialog(biliPath);
              if (scanResult == null || !mounted) return;
              final scanResults = (scanResult['results'] as List<ShizukuScanResult>?) ?? [];
              final scanDiag = (scanResult['diagnostic'] as String?) ?? '';
              if (scanResults.isNotEmpty && mounted) {
                await controller.buildFromShizukuScan(scanResults, await ShellCopyService.getTempPath(), scanDiag);
                return;
              }
            }
          }
        }
      }
    }

    // ─── 方案 2：Shell 复制（仅 root）────────────────
    if (await ShellCopyService.isRootAvailable()) {
      _snack("正在通过 Shell 复制缓存文件...");
      final shellResult = await ShellCopyService.copyViaShell(sourceDir: biliPath);
      if (shellResult) {
        _snack("复制完成，正在扫描...");
        await _scanDirectory(await ShellCopyService.getTempPath());
        return;
      }
    }

    // ─── 方案 3：MT 管理器引导 ──────────────────────
    final mtLaunched = await ShellCopyService.launchMTManager();
    final action = await dialogs.showMTManagerGuideDialog(context, mtLaunched);
    if (action == null || !mounted) return;

    if (action == "pick") {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: "请选择用MT管理器复制到的目录（如 Download/bili_cache）"
      );
      if (picked == null) return;

      if (ShellCopyService.isSafUri(picked)) {
        _snack("正在通过 SAF 复制...");
        final count = await ShellCopyService.copyViaSaf(picked);
        if (count > 0) {
          await _scanDirectory(await ShellCopyService.getTempPath());
          return;
        }
      }
      _snack("正在扫描...");
      await _scanDirectory(picked);
    }
  }

  /// 仅扫描进度对话框 — 实时显示扫描到哪个视频
  /// 返回 scanViaShizuku 的 Map 结果，或 null（取消/失败）
  Future<Map<String, dynamic>?> _showScanProgressDialog(String biliPath) async {
    int done = 0, total = 0;
    String currentFile = '准备中...';
    void Function(void Function())? _setDlgState;

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          _setDlgState = setDlgState;
          final progress = total > 0 ? done / total : 0.0;
          return AlertDialog(
            title: const Text("正在扫描缓存"),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: progress > 0 ? progress : null),
                const SizedBox(height: 12),
                if (total > 0)
                  Text("$done / $total", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.indigo[600])),
                const SizedBox(height: 4),
                Text(currentFile, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ]),
            ),
          );
        },
      ),
    ));

    await Future.delayed(const Duration(milliseconds: 100));

    final coversDir = await SettingsService.getCoversDir();
    final result = await ShellCopyService.scanViaShizuku(
      biliPath,
      onProgress: (file, d, t) {
        done = d;
        total = t;
        currentFile = file;
        _setDlgState?.call(() {});
      },
      coversDir: coversDir,
    );

    if (mounted) Navigator.of(context).pop();
    return result;
  }

  Future<void> _scanDirectory(String path) async {
    await controller.scanDirectory(path);
  }

  Future<void> _cleanTempFiles() async {
    final hasFiles = await controller.hasTempFiles();
    if (!hasFiles) { _snack("没有临时缓存"); return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("清除缓存"),
        content: Text("确定清除临时缓存文件？"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("清除"), style: FilledButton.styleFrom(backgroundColor: Colors.red)),
        ],
      ),
    );
    if (ok == true) {
      await controller.cleanTempFiles();
      _snack("已清除");
    }
  }

  void _exitSelectMode() => controller.exitSelectMode();

  Future<void> _play(BiliVideo v) async {
    // 仅扫描模式：m4s 文件不在本地，需通过 Shizuku 复制后再播放
    if (v.isScanOnly && v.originalMediaPath != null) {
      _snack("正在准备播放...");
      final cacheDir = await getTemporaryDirectory();
      final playDir = "${cacheDir.path}/bili_play_${v.cid}";

      // 先弹出进度对话框（不阻塞复制）
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text("准备播放"),
          ]),
          content: Text("正在复制视频到应用缓存...\n大文件可能需要较长时间"),
        ),
      ));
      await Future.delayed(const Duration(milliseconds: 100)); // 等对话框渲染

      // 执行复制
      final ok = await ShellCopyService.copyForExportViaShizuku(
        originalMediaPath: v.originalMediaPath!,
        destMediaPath: playDir,
      );

      if (mounted) Navigator.of(context).pop(); // 关闭进度对话框

      if (!ok) { _snack("无法复制视频文件"); return; }
      final playFile = File("$playDir/video.m4s");
      try {
        await OpenFile.open(playFile.path);
        // 30秒后自动清理
        Future.delayed(const Duration(seconds: 30), () {
          if (Directory(playDir).existsSync()) Directory(playDir).deleteSync(recursive: true);
        });
      } catch (e) {
        _snack("播放失败: $e");
      }
      return;
    }

    final src = File(v.videoPath);
    if (!await src.exists()) { _snack("视频文件不存在"); return; }

    // 非 scan-only：文件已在本地临时目录，直接复制
    final cacheDir = await getTemporaryDirectory();
    final playFile = File("${cacheDir.path}/bili_play_${v.cid}.m4s");
    try {
      await src.copy(playFile.path);
      await OpenFile.open(playFile.path);
      // 5秒后自动清理播放缓存
      Future.delayed(const Duration(seconds: 5), () {
        if (playFile.existsSync()) playFile.deleteSync();
      });
    } catch (e) {
      // 如果复制失败，尝试直接打开原始路径（旧设备上可能可行）
      try { await OpenFile.open(v.videoPath); } catch (_) {}
    }
  }

  Future<void> _export(BiliVideo v) => _exportWithConfirm([v]);
  Future<void> _exportBatch(List<BiliVideo> list) => _exportWithConfirm(list);

  Future<void> _exportWithConfirm(List<BiliVideo> list, {String? forcedDir}) async {
    // 导出目录选择：确定 → /Download/Bilimerge，新建文件夹 → 输入名称创建子目录
    // 如果 forcedDir 非空则跳过对话框
    String? customDir = forcedDir;
    if (customDir == null) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text("导出 ${list.length} 个视频"),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("合计: ${list.length} 个, 共 ${fmtSize(list.fold(0, (s, v) => s + v.totalBytes))}"),
            const SizedBox(height: 12),
            Text("导出到 /Download/Bilimerge", style: TextStyle(fontSize: 13)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, "cancel"), child: const Text("取消")),
            OutlinedButton(onPressed: () => Navigator.pop(ctx, "new"), child: const Text("新建导出文件夹")),
            FilledButton(onPressed: () => Navigator.pop(ctx, "default"), child: const Text("确定")),
          ],
        ),
      );
      if (choice == null || choice == "cancel" || !mounted) return;

      if (choice == "new") {
        // 用户输入子文件夹名称
        String? folderName;
        await showDialog<String>(
          context: context,
          builder: (ctx) {
            final nameController = TextEditingController();
            return AlertDialog(
              title: const Text("新建导出文件夹"),
              content: TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: "输入文件夹名称",
                  border: OutlineInputBorder(),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
                FilledButton(onPressed: () {
                  folderName = nameController.text.trim();
                  Navigator.pop(ctx);
                }, child: const Text("创建")),
              ],
            );
          },
        );
        final folder = folderName;
        if (folder == null || folder.isEmpty || !mounted) return;
        final name = folderName;
        // 在 /Download/Bilimerge 下创建子目录
        final base = await ExportService.getExportDirectory();
        customDir = "$base/$name";
        final dir = Directory(customDir);
        if (!await dir.exists()) await dir.create(recursive: true);
      } else {
        // "default" → /Download/Bilimerge
        customDir = await ExportService.getExportDirectory();
      }
    }

    _exitSelectMode();
    int exportDone = 0;
    int exportTotal = list.length;
    int exportSkippedCnt = 0;
    String exportCurrent = "准备中...";
    bool exportCancelled = false;
    void Function(VoidCallback)? _setExportDlgState;
    // 运行计时器：每秒更新，让用户看到数字在走，知道程序没卡死
    final _exportStopwatch = Stopwatch()..start();
    Timer? _exportTimer;

    // 弹出可实时更新的进度对话框
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          _setExportDlgState = setDlgState;
          final elapsed = _exportStopwatch.elapsed;
          final min = elapsed.inMinutes;
          final sec = elapsed.inSeconds % 60;
          final timeStr = "${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}";
          return AlertDialog(
            title: Row(children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text("导出 ($exportDone/$exportTotal)"),
            ]),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                      value: exportTotal > 0 ? exportDone / exportTotal : null),
                  const SizedBox(height: 12),
                  Text(
                    exportCancelled ? "正在取消..." : exportCurrent,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    exportDone > 0
                        ? "已用 $timeStr · 平均 ${(elapsed.inSeconds / exportDone).clamp(1, 9999)}s/个"
                        : "已用 $timeStr",
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            actions: [
              if (!exportCancelled)
                TextButton(
                  onPressed: () {
                    exportCancelled = true;
                    setDlgState(() {});
                  },
                  child: const Text("取消"),
                ),
            ],
          );
        },
      ),
    ));
    // 起一个每秒定时器，刷新对话框中的计时显示
    _exportTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _setExportDlgState?.call(() {});
    });
    // 等 100ms 让对话框渲染完毕，再开始 CPU 密集的合并
    await Future.delayed(const Duration(milliseconds: 100));

    // 手动逐条导出，每完成一个实时更新对话框
    final results = <ExportResult>[];
    final errors = <String>[]; // 收集失败信息用于汇总提示
    for (int i = 0; i < list.length && !exportCancelled; i++) {
      final v = list[i];
      exportCurrent = "${v.title} (${v.ownerName})";
      _setExportDlgState?.call(() {});

      ExportResult r;
      String? errorDetail;
      try {
        r = await ExportService.exportVideo(v, customDir: customDir);
        if (!r.success) {
          errorDetail = r.error ?? "未知错误";
        }
      } catch (e) {
        errorDetail = "$e";
        r = ExportResult(false, error: "$e");
      }
      results.add(r);

      if (errorDetail != null) {
        errors.add("${v.title} (${v.ownerName}): $errorDetail");
        // 记录到诊断日志
        unawaited(DiagnosticLogService.addEntry(
            "[导出失败] ${v.title} (${v.avid})\n"
            "  UP主: ${v.ownerName}\n"
            "  路径: ${v.folderPath}\n"
            "  错误: $errorDetail"));
      }

      if (r.success) {
        if (r.skipped) exportSkippedCnt++;
        exportDone++;
      }
      _setExportDlgState?.call(() {});
    }

    if (!mounted) return;
    _exportTimer.cancel();
    _exportStopwatch.stop();
    Navigator.of(context).pop();
    final ok = results.where((r) => r.success).toList();
    if (exportCancelled) { _snack("导出已取消"); return; }
    if (ok.isEmpty) {
      // 全部失败 → 弹对话框，允许重新选目录或取消
      final shouldRetry = await _showExportFailedDialog(errors, list);
      if (shouldRetry == true && mounted) {
        // 重新选目录
        final newDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: "重新选择导出目录",
        );
        if (newDir != null && mounted) {
          await SettingsService.setLastExportPath(newDir);
          await _exportWithConfirm(list, forcedDir: newDir);
        }
      }
      return;
    }
    final failCount = list.length - ok.length;
    if (failCount > 0) {
      _snack("成功 ${ok.length}/$exportTotal · $failCount 个失败${exportSkippedCnt > 0 ? " ($exportSkippedCnt 个已存在跳过)" : ""}，详见 📄 诊断日志");
    } else if (exportSkippedCnt > 0) {
      final newlyExported = exportDone - exportSkippedCnt;
      if (newlyExported > 0) {
        _snack("成功 ${newlyExported}/$exportTotal ($exportSkippedCnt 个已存在跳过)");
      } else {
        _snack("$exportSkippedCnt 个文件已存在，无需重复导出");
      }
    } else {
      _snack("成功 $exportTotal/$exportTotal");
    }
    // 刷新已导出状态
    unawaited(_refreshExportedKeys());

    // ── 导出完成后询问是否标记删除源文件 ────────────
    final del = await dialogs.showBatchDeleteConfirmDialog(context, list);
    if (del == true && mounted) {
      final results = await DeleteService.markBatchForDeletion(list);
      final okCount = results.where((r) => r.success).length;
      controller.videos.removeWhere((v) => list.contains(v));
      setState(() {});
      await controller.saveCache();
      if (okCount == list.length) {
        _snack("已删除 $okCount/${list.length} 个文件夹");
      } else {
        _snack("删除完成，$okCount/${list.length} 成功（详见诊断日志）");
      }
    }
    // 自动清理临时缓存
    final tempPath = await ShellCopyService.getTempPath();
    if (await Directory(tempPath).exists()) { await ShellCopyService.cleanTemp(); }
  }

  Future<void> _deleteSingle(BiliVideo video) async {
    final info = await DeleteService.getFolderInfo(video);
    if (!mounted) return;
    final ok = await dialogs.showDeleteDetailDialog(context, video, info);
    if (!ok || !mounted) return;

    final result = await DeleteService.markForDeletion(video);
    if (!mounted) return;
    if (result.success) {
      setState(() {
        controller.videos.removeWhere(
            (v) => v.avid == video.avid && v.title == video.title);
      });
      await controller.saveCache();
      _snack("已删除: ${video.title}");
    } else {
      _snack("删除失败: ${result.errorMessage ?? "未知错误"}");
    }
  }

  Future<void> _deleteSelected() async {
    final list = controller.selectedVideos;
    if (list.isEmpty) return;
    if (!await dialogs.showBatchDeleteConfirmDialog(context, list)) return;

    final results = await DeleteService.markBatchForDeletion(list);
    if (!mounted) return;
    final okCount = results.where((r) => r.success).length;
    final failCount = results.where((r) => !r.success).length;

    controller.videos.removeWhere((v) => list.contains(v));
    controller.exitSelectMode();
    setState(() {});
    await controller.saveCache();
    if (failCount > 0) {
      _snack("删除: 成功 $okCount/${list.length}，$failCount 个失败（详见诊断日志）");
    } else {
      _snack("已删除 $okCount 个文件夹");
    }
  }

  Future<void> _exportAllUnmerged() async {
    final u = controller.videos.where((v) => !v.isMerged).toList();
    if (u.isEmpty) { _snack("没有未导出的视频"); return; }
    await _exportWithConfirm(u);
  }

  /// 全部导出失败时弹出对话框，显示错误详情，提供重新选目录或取消
  Future<bool> _showExportFailedDialog(List<String> errors, List<BiliVideo> list) async {
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("导出全部失败"),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("${list.length} 个视频全部导出失败，错误详情：",
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: errors.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(e, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                    )).toList(),
                  ),
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
            child: const Text("重新选择目录"),
          ),
        ],
      ),
    ) ?? false;
  }

  /// 打开 /Download/Bilimerge 导出目录（系统选择打开方式）
  Future<void> _openExportFolder() async {
    final dir = await ExportService.getExportDirectory();
    if (await Directory(dir).exists()) {
      OpenFile.open(dir);
    }
  }

  /// Snackbar shortcut
  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: _buildBody(),
      bottomSheet: controller.selectMode && controller.selectedCount > 0
          ? BatchActionBar(
              selectedCount: controller.selectedCount,
              onExport: controller.selectedVideos.any((v) => !v.isMerged)
                  ? () => _exportBatch(controller.selectedVideos)
                  : null,
              onDelete: _deleteSelected,
            )
          : null,
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Text(controller.selectMode ? "已选 ${controller.selectedCount} 项" : "BiliMerge"),
      centerTitle: false,
      automaticallyImplyLeading: false,
      leading: controller.selectMode ? IconButton(icon: const Icon(Icons.close), onPressed: _exitSelectMode) : null,
      actions: [
        if (!controller.selectMode) ...[
          // 主要操作 — 始终可见
          IconButton(icon: const Icon(Icons.folder_open), tooltip: "打开导出目录 (Download/Bilimerge)", onPressed: _openExportFolder),
          IconButton(icon: const Icon(Icons.article_outlined), tooltip: "诊断日志", onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticLogScreen()))),
          // 待导出队列
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.playlist_play),
                tooltip: "待导出队列 (${controller.pendingCount})",
                onPressed: () async {
                  final videos = await Navigator.push<List<BiliVideo>>(
                    context,
                    MaterialPageRoute(builder: (_) => PendingExportScreen(
                      controller: controller,
                    )),
                  );
                  if (videos != null && videos.isNotEmpty && mounted) {
                    _exportWithConfirm(videos);
                  } else if (mounted) {
                    setState(() {});
                  }
                },
              ),
              if (controller.pendingCount > 0)
                Positioned(
                  right: 2,
                  top: 2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      "${controller.pendingCount}",
                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          // 溢出菜单 — 次要操作
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: "更多",
            onSelected: (value) {
              switch (value) {
                case 'openBiliCache':
                  _openBiliCache();
                  break;
                case 'openExportFolder':
                  _openExportFolder();
                  break;
                case 'delete':
                  controller.enterSelectMode();
                  break;
                case 'history':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ExportHistoryScreen()));
                  break;
                case 'exportAll':
                  _exportAllUnmerged();
                  break;
                case 'settings':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(
                    onCacheCleared: () {
                      controller.clearVideos();
                    },
                    onPickDir: _pickDir,
                  ))).then((_) => _refreshExportedKeys());
                  break;
                case 'cleanTemp':
                  _cleanTempFiles();
                  break;
                case 'coverStatus':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => CoverDownloadScreen(
                    videos: controller.videos,
                    coversDir: controller.coverDir ?? '',
                    onPlay: _play,
                    onExport: _export,
                    onCoverRefreshed: () { if (mounted) setState(() {}); },
                  )));
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'openBiliCache', child: Row(children: [Icon(Icons.cloud_download, size: 20), SizedBox(width: 12), Text("加载B站缓存")])),
              const PopupMenuItem(value: 'openExportFolder', child: Row(children: [Icon(Icons.download, size: 20), SizedBox(width: 12), Text("打开导出目录")])),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'exportAll', child: Row(children: [Icon(Icons.file_download, size: 20), SizedBox(width: 12), Text("导出全部")])),
              const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 20), SizedBox(width: 12), Text("删除")])),
              const PopupMenuItem(value: 'history', child: Row(children: [Icon(Icons.history, size: 20), SizedBox(width: 12), Text("导出历史")])),
              const PopupMenuItem(value: 'cleanTemp', child: Row(children: [Icon(Icons.cleaning_services, size: 20), SizedBox(width: 12), Text("清除缓存")])),
              const PopupMenuItem(value: 'coverStatus', child: Row(children: [Icon(Icons.image, size: 20), SizedBox(width: 12), Text("封面加载情况")])),
              const PopupMenuItem(value: 'settings', child: Row(children: [Icon(Icons.settings, size: 20), SizedBox(width: 12), Text("设置")])),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildBody() {
    if (controller.loading) return const Center(child: CircularProgressIndicator());
    if (controller.rootPath == null) {
      return WelcomeView(onLoadBiliCache: _openBiliCache, onOpenExportFolder: _openExportFolder);
    }
    if (controller.error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.warning_amber, size: 48, color: Colors.orange[300]),
        const SizedBox(height: 16), Text(controller.error!, textAlign: TextAlign.center),
        if (controller.diagnosticInfo != null) const SizedBox(height: 8),
        if (controller.diagnosticInfo != null) Text(controller.diagnosticInfo!, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        const SizedBox(height: 16), OutlinedButton(onPressed: _pickDir, child: const Text("重新选择")),
      ])));
    }
    if (controller.videos.isEmpty) return const Center(child: Text("空目录"));
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: controller.sortedVideos.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text("共 ${controller.sortedVideos.length} 个视频", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              SortBar(sortField: controller.sortField, sortOrder: controller.sortOrder, onToggle: (field) {
                controller.toggleSort(field);
              }),
            ]),
            CoverDownloadIndicator(
              videos: controller.videos,
              coverDir: controller.coverDir ?? '',
              onPlay: _play,
              onExport: _export,
              onCoverRefreshed: () { if (mounted) setState(() {}); },
            ),
            const Divider(),
          ]));
        }
        final v = controller.sortedVideos[i - 1];
        return VideoRow(
          video: v,
          coverDir: controller.coverDir,
          exported: controller.exportedKeys.contains(controller.exportKey(v)),
          selected: controller.isSelected(i - 1),
          selectMode: controller.selectMode,
          onTap: () => controller.selectMode ? controller.toggleSelect(i - 1) : _play(v),
          onLongPress: () {
            if (!controller.selectMode) controller.enterSelectMode(i - 1);
          },
          onExport: () => _export(v),
          onTogglePending: () => controller.togglePendingExport(v),
          pending: controller.isPendingExport(v),
          onDelete: () => _deleteSingle(v),
        );
      },
    );
  }
}
