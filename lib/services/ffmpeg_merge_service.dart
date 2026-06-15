/// FFmpeg 音视频合并服务
///
/// 使用 ffmpeg-kit 的 -c copy（流复制）替代 Android MediaMuxer，
/// 避免 Java/Kotlin 层 per-frame JNI 往返开销。
///
/// 命令等价于：
///   ffmpeg -i video.m4s -i audio.m4s -map 0:v:0 -map 1:a:0 -c copy -y output.mp4
///
/// 只打包 arm64-v8a 的 so，APK 增量约 3~5MB。
import "dart:io";
import "package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart";
import "package:ffmpeg_kit_flutter_min_gpl/return_code.dart";

class FfmpegMergeService {
  /// 用 FFmpeg -c copy 合并音视频（零重编码，速度 50~200MB/s）
  ///
  /// [videoPath] video.m4s 路径
  /// [audioPath] audio.m4s 路径
  /// [outputPath] 输出 .mp4 路径
  /// 返回 [MergeResult]（接口与 MergeService 兼容）
  static Future<FfmpegMergeResult> mergeVideo({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    if (!File(videoPath).existsSync()) {
      return FfmpegMergeResult(success: false, errorMessage: "视频文件不存在: $videoPath");
    }
    if (!File(audioPath).existsSync()) {
      return FfmpegMergeResult(success: false, errorMessage: "音频文件不存在: $audioPath");
    }

    // 确保输出目录存在
    final outDir = File(outputPath).parent;
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    final cmd = "-i \"$videoPath\" -i \"$audioPath\" -map 0:v:0 -map 1:a:0 -c copy -y \"$outputPath\"";
    final stopwatch = Stopwatch()..start();

    try {
      final session = await FFmpegKit.execute(cmd);
      final returnCode = await session.getReturnCode();
      final logs = await session.getAllLogsAsString();
      final durationMs = stopwatch.elapsedMilliseconds;

      if (ReturnCode.isSuccess(returnCode)) {
        final f = File(outputPath);
        final size = await f.length();
        return FfmpegMergeResult(
          success: true,
          outputPath: outputPath,
          fileSize: size,
          totalMs: durationMs,
        );
      } else {
        final failLogs = await session.getAllLogs();
        String errorMsg = "FFmpeg 合并失败";
        for (final log in failLogs) {
          if (log.getMessage().contains("Error") || log.getMessage().contains("error")) {
            errorMsg = log.getMessage();
            break;
          }
        }
        return FfmpegMergeResult(
          success: false,
          errorMessage: errorMsg.trim(),
          totalMs: durationMs,
          stderr: logs,
        );
      }
    } catch (e) {
      return FfmpegMergeResult(
        success: false,
        errorMessage: "FFmpeg 异常: $e",
        totalMs: stopwatch.elapsedMilliseconds,
      );
    }
  }
}

class FfmpegMergeResult {
  final bool success;
  final String? errorMessage;
  final String? outputPath;
  final int? fileSize;
  final int? totalMs;
  final String? stderr;

  FfmpegMergeResult({
    required this.success,
    this.errorMessage,
    this.outputPath,
    this.fileSize,
    this.totalMs,
    this.stderr,
  });

  /// 格式化的耗时摘要
  String get timingSummary {
    if (totalMs == null) return "无耗时数据";
    final buf = StringBuffer();
    buf.write("总耗时: ${_fmtMs(totalMs!)}");
    if (fileSize != null) {
      final mb = fileSize! / (1024 * 1024);
      buf.write("  输出: ${mb.toStringAsFixed(1)}MB");
      if (totalMs! > 0) {
        buf.write("  速度: ${(mb / (totalMs! / 1000)).toStringAsFixed(1)}MB/s");
      }
    }
    return buf.toString();
  }

  static String _fmtMs(int ms) {
    if (ms < 1000) return "${ms}ms";
    return "${(ms / 1000).toStringAsFixed(1)}s";
  }
}
