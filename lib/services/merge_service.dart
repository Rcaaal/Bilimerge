import "dart:io";
import "package:flutter/services.dart";

class MergeService {
  static const _channel = MethodChannel("com.personal.bilimerge/merge");

  static Future<MergeResult> mergeBiliVideo({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    if (!File(videoPath).existsSync()) return MergeResult(success: false, errorMessage: "视频文件不存在");
    if (!File(audioPath).existsSync()) return MergeResult(success: false, errorMessage: "音频文件不存在");

    try {
      final result = await _channel.invokeMethod<Map>("mergeAudioVideo", {
        "videoPath": videoPath,
        "audioPath": audioPath,
        "outputPath": outputPath,
      });

      if (result == null) return MergeResult(success: false, errorMessage: "合并返回 null");

      final success = result['success'] == true;
      final videoReadMs = result['videoReadMs'] as int?;
      final audioReadMs = result['audioReadMs'] as int?;
      final muxerStopMs = result['muxerStopMs'] as int?;
      final totalMs = result['totalMs'] as int?;

      if (success) {
        final f = File(outputPath);
        if (await f.exists()) {
          return MergeResult(
            success: true,
            outputPath: outputPath,
            fileSize: await f.length(),
            videoReadMs: videoReadMs,
            audioReadMs: audioReadMs,
            muxerStopMs: muxerStopMs,
            totalMs: totalMs,
          );
        }
        return MergeResult(success: false, errorMessage: "输出文件未生成");
      }
      final errorMsg = result['errorMessage'] as String? ?? "未知合并错误";
      return MergeResult(
        success: false,
        errorMessage: errorMsg,
        videoReadMs: videoReadMs,
        audioReadMs: audioReadMs,
        muxerStopMs: muxerStopMs,
        totalMs: totalMs,
      );
    } on PlatformException catch (e) {
      return MergeResult(success: false, errorMessage: "平台异常: ${e.message}");
    } catch (e) {
      return MergeResult(success: false, errorMessage: "合并异常: $e");
    }
  }
}

class MergeResult {
  final bool success;
  final String? errorMessage;
  final String? outputPath;
  final int? fileSize;

  /// 合并各阶段耗时（ms），仅成功时有效
  final int? videoReadMs;   // 读取并写入视频轨道
  final int? audioReadMs;   // 读取并写入音频轨道
  final int? muxerStopMs;   // MediaMuxer.stop() 耗时
  final int? totalMs;       // 总耗时

  MergeResult({
    required this.success,
    this.errorMessage,
    this.outputPath,
    this.fileSize,
    this.videoReadMs,
    this.audioReadMs,
    this.muxerStopMs,
    this.totalMs,
  });

  /// 格式化的耗时摘要，用于诊断日志
  String get timingSummary {
    if (totalMs == null) return "无耗时数据";
    final buf = StringBuffer();
    buf.write("总耗时: ${_fmtMs(totalMs!)}");
    if (videoReadMs != null) buf.write("  视频: ${_fmtMs(videoReadMs!)}");
    if (audioReadMs != null) buf.write("  音频: ${_fmtMs(audioReadMs!)}");
    if (muxerStopMs != null) buf.write("  封包: ${_fmtMs(muxerStopMs!)}");
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
