package com.personal.bilimerge;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

import rikka.shizuku.Shizuku;

public class MediaMergePlugin implements FlutterPlugin, MethodCallHandler, ActivityAware {
    private static final int SHIZUKU_REQUEST_CODE = 10001;

    private MethodChannel channel;
    private Context context;
    @Nullable
    private Activity activity;
    private volatile boolean shizukuPermissionRequested = false;
    private volatile boolean shizukuPermissionResult = false;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "com.personal.bilimerge/merge");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
        context = null;
        activity = null;
    }

    // ─── ActivityAware ──────────────────────────────────

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
    }

    // ─── Method Call Dispatcher ──────────────────────────

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        switch (call.method) {
            case "mergeAudioVideo":
                handleMerge(call, result);
                break;
            case "copyFromSafUri":
                handleCopyFromSaf(call, result);
                break;
            case "checkShizuku":
                handleCheckShizuku(result);
                break;
            case "requestShizukuPermission":
                handleRequestShizukuPermission(result);
                break;
            case "executeShellViaShizuku":
                handleExecuteShell(call, result);
                break;
            case "readFileBytes":
                handleReadFileBytes(call, result);
                break;
            case "copyFileForExport":
                handleCopyFileForExport(call, result);
                break;
            case "streamSingleFile":
                handleStreamSingleFile(call, result);
                break;
            case "deletePath":
                handleDeletePath(call, result);
                break;
            case "deleteViaSaf":
                handleDeleteViaSaf(call, result);
                break;
            case "openFolder":
                handleOpenFolder(call, result);
                break;
            default:
                result.notImplemented();
        }
    }

    // ─── Shizuku: 状态检查 ─────────────────────────────

    private static final String SHIZUKU_PACKAGE = "moe.shizuku.privileged.api";

    private void handleCheckShizuku(Result result) {
        Map<String, Object> map = new HashMap<>();
        try {
            // 1. 检查 Shizuku App 是否已安装
            boolean installed = false;
            try {
                context.getPackageManager().getPackageInfo(SHIZUKU_PACKAGE, 0);
                installed = true;
            } catch (Exception ignored) {}
            map.put("installed", installed);

            // 2. 检查 Shizuku 服务是否正在运行
            boolean available = false;
            try {
                available = Shizuku.pingBinder();
            } catch (Exception ignored) {}
            map.put("available", available);

            if (available) {
                int uid = Shizuku.getUid();
                int version = Shizuku.getVersion();
                map.put("hasPermission", uid != -1);
                map.put("version", version);
            } else {
                map.put("hasPermission", false);
                map.put("version", -1);
            }
        } catch (Exception e) {
            map.put("installed", false);
            map.put("available", false);
            map.put("hasPermission", false);
            map.put("error", e.getMessage());
        }
        result.success(map);
    }

    // ─── Shizuku: 请求权限 ─────────────────────────────

    private void handleRequestShizukuPermission(Result result) {
        if (activity == null) {
            result.success(false);
            return;
        }
        if (!Shizuku.pingBinder()) {
            result.success(false);
            return;
        }

        // 如果已有权限，直接返回成功
        try {
            if (Shizuku.getUid() != -1) {
                result.success(true);
                return;
            }
        } catch (Exception ignored) {}

        shizukuPermissionRequested = true;
        shizukuPermissionResult = false;

        // 在主线程请求权限
        activity.runOnUiThread(() -> {
            Shizuku.OnRequestPermissionResultListener listener =
                new Shizuku.OnRequestPermissionResultListener() {
                    @Override
                    public void onRequestPermissionResult(int requestCode, int grantResult) {
                        // 0 = PERMISSION_GRANTED, -1 = PERMISSION_DENIED
                        shizukuPermissionResult = grantResult == 0;
                        shizukuPermissionRequested = false;
                    }
                };

            Shizuku.addRequestPermissionResultListener(listener);
            Shizuku.requestPermission(SHIZUKU_REQUEST_CODE);

            // 超时清理：15秒后如果还没响应，标记为失败
            new Handler(Looper.getMainLooper()).postDelayed(() -> {
                Shizuku.removeRequestPermissionResultListener(listener);
                if (shizukuPermissionRequested) {
                    shizukuPermissionRequested = false;
                    shizukuPermissionResult = false;
                }
            }, 15000);
        });

        // 等待用户响应（最多 15 秒）
        long deadline = System.currentTimeMillis() + 15000;
        while (shizukuPermissionRequested && System.currentTimeMillis() < deadline) {
            try { Thread.sleep(100); } catch (InterruptedException e) { break; }
        }

        result.success(shizukuPermissionResult);
    }

    // ─── Shizuku: 执行 Shell 命令 ──────────────────────

    private void handleExecuteShell(MethodCall call, Result result) {
        String command = call.argument("command");
        if (command == null) {
            result.error("INVALID_ARGS", "Missing command", null);
            return;
        }

        new Thread(() -> {
            try {
                executeShellViaShizuku(command, result);
            } catch (Exception e) {
                new Handler(Looper.getMainLooper()).post(() ->
                    result.error("SHIZUKU_EXEC_ERROR", e.getMessage(), null));
            }
        }).start();
    }

    private void executeShellViaShizuku(String command, Result result) {
        new Thread(() -> {
            try {
                // Shizuku.newProcess() 在 AAR 中标记为 private，通过反射调用
                Method newProcess;
                Process process;
                try {
                    newProcess = Shizuku.class.getDeclaredMethod(
                            "newProcess", String[].class, String[].class, String.class);
                    newProcess.setAccessible(true);
                    process = (Process) newProcess.invoke(null,
                            new String[]{"sh", "-c", command}, null, null);
                } catch (NoSuchMethodException | IllegalAccessException |
                         InvocationTargetException e) {
                    // 反射失败，返回详细错误信息
                    Map<String, Object> err = new HashMap<>();
                    err.put("exitCode", -2);
                    err.put("stdout", "");
                    err.put("stderr", "Shizuku反射失败: " + e.getClass().getSimpleName()
                            + ": " + e.getMessage());
                    Map<String, Object> finalErr = err;
                    new Handler(Looper.getMainLooper()).post(() -> result.success(finalErr));
                    return;
                }

                if (process == null) {
                    Map<String, Object> err = new HashMap<>();
                    err.put("exitCode", -3);
                    err.put("stdout", "");
                    err.put("stderr", "Shizuku.newProcess 返回 null");
                    new Handler(Looper.getMainLooper()).post(() -> result.success(err));
                    return;
                }

                // 读取 stdout
                StringBuilder stdout = new StringBuilder();
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(process.getInputStream()))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        stdout.append(line).append("\n");
                    }
                }

                // 读取 stderr
                StringBuilder stderr = new StringBuilder();
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(process.getErrorStream()))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        stderr.append(line).append("\n");
                    }
                }

                int exitCode = process.waitFor();

                Map<String, Object> map = new HashMap<>();
                map.put("stdout", stdout.toString());
                map.put("stderr", stderr.toString());
                map.put("exitCode", exitCode);

                new Handler(Looper.getMainLooper()).post(() -> result.success(map));
            } catch (Exception e) {
                Map<String, Object> err = new HashMap<>();
                err.put("exitCode", -4);
                err.put("stdout", "");
                err.put("stderr", "Shizuku执行异常: " + e.getClass().getSimpleName()
                        + ": " + e.getMessage());
                new Handler(Looper.getMainLooper()).post(() -> result.success(err));
            }
        }).start();
    }

    // ─── Shizuku: 读取原始文件字节 ──────────────────────

    private void handleReadFileBytes(MethodCall call, Result result) {
        String filePath = call.argument("filePath");
        if (filePath == null) {
            result.error("INVALID_ARGS", "Missing filePath", null);
            return;
        }

        new Thread(() -> {
            try {
                Method newProcess = Shizuku.class.getDeclaredMethod(
                        "newProcess", String[].class, String[].class, String.class);
                newProcess.setAccessible(true);
                Process process = (Process) newProcess.invoke(null,
                        new String[]{"cat", filePath}, null, null);

                if (process == null) {
                    new Handler(Looper.getMainLooper()).post(() ->
                        result.error("READ_FAILED", "process is null", null));
                    return;
                }

                // 读取原始字节（不经过 Reader，避免编码损坏）
                java.io.InputStream input = process.getInputStream();
                java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
                byte[] chunk = new byte[64 * 1024];
                int n;
                while ((n = input.read(chunk)) != -1) {
                    buffer.write(chunk, 0, n);
                }
                byte[] fileBytes = buffer.toByteArray();

                int exitCode = process.waitFor();
                if (exitCode != 0 || fileBytes.length == 0) {
                    new Handler(Looper.getMainLooper()).post(() ->
                        result.error("READ_FAILED", "exit=" + exitCode + " size=" + fileBytes.length, null));
                    return;
                }

                new Handler(Looper.getMainLooper()).post(() -> result.success(fileBytes));
            } catch (Exception e) {
                new Handler(Looper.getMainLooper()).post(() ->
                    result.error("READ_ERROR", e.getClass().getSimpleName() + ": " + e.getMessage(), null));
            }
        }).start();
    }

    // ─── Shizuku: 流式复制文件（不分配大内存，避免 OOM）──

    private void handleCopyFileForExport(MethodCall call, Result result) {
        String originalMediaPath = call.argument("originalMediaPath");
        String destMediaPath = call.argument("destMediaPath");
        if (originalMediaPath == null || destMediaPath == null) {
            result.error("INVALID_ARGS", "Missing args", null);
            return;
        }

        new Thread(() -> {
            try {
                new File(destMediaPath).mkdirs();
                boolean videoOk = streamFileViaShizuku(
                    originalMediaPath + "/video.m4s",
                    destMediaPath + "/video.m4s"
                );
                boolean audioOk = streamFileViaShizuku(
                    originalMediaPath + "/audio.m4s",
                    destMediaPath + "/audio.m4s"
                );
                boolean success = videoOk && audioOk;
                new Handler(Looper.getMainLooper()).post(() -> result.success(success));
            } catch (Exception e) {
                new Handler(Looper.getMainLooper()).post(() -> result.success(false));
            }
        }).start();
    }

    /** 流式复制单个文件（Shizuku cat + 64KB buffer），用于全量复制 */
    private void handleStreamSingleFile(MethodCall call, Result result) {
        String src = call.argument("src");
        String dst = call.argument("dst");
        if (src == null || dst == null) {
            result.error("INVALID_ARGS", "Missing src or dst", null);
            return;
        }
        new Thread(() -> {
            boolean ok = streamFileViaShizuku(src, dst);
            new Handler(Looper.getMainLooper()).post(() -> result.success(ok));
        }).start();
    }

    /** 通过 Shizuku cat + 64KB buffer 流式复制，零大内存分配 */
    private boolean streamFileViaShizuku(String srcPath, String dstPath) {
        try {
            Method newProcess = Shizuku.class.getDeclaredMethod(
                    "newProcess", String[].class, String[].class, String.class);
            newProcess.setAccessible(true);
            Process process = (Process) newProcess.invoke(null,
                    new String[]{"cat", srcPath}, null, null);
            if (process == null) return false;

            try (InputStream in = process.getInputStream();
                 FileOutputStream out = new FileOutputStream(dstPath)) {
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) != -1) {
                    out.write(buf, 0, n);
                }
            }

            int exitCode = process.waitFor();
            return exitCode == 0 && new File(dstPath).length() > 0;
        } catch (Exception e) {
            return false;
        }
    }

    // ─── Shizuku: 删除文件（多策略，详细错误） ───────────

    /** 通过 Shizuku 删除目录，尝试多种策略，返回详细结果
     *  result map: {success: bool, exitCode: int, stdout: String, stderr: String}
     */
    private void handleDeletePath(MethodCall call, Result result) {
        String path = call.argument("path");
        if (path == null || path.isEmpty()) {
            Map<String, Object> err = new HashMap<>();
            err.put("success", false);
            err.put("exitCode", -1);
            err.put("stdout", "");
            err.put("stderr", "路径为空");
            result.success(err);
            return;
        }

        new Thread(() -> {
            try {
                Map<String, Object> finalResult = deletePathViaShizuku(path);
                new Handler(Looper.getMainLooper()).post(() -> result.success(finalResult));
            } catch (Exception e) {
                Map<String, Object> err = new HashMap<>();
                err.put("success", false);
                err.put("exitCode", -5);
                err.put("stdout", "");
                err.put("stderr", "deletePath异常: " + e.getClass().getSimpleName() + ": " + e.getMessage());
                new Handler(Looper.getMainLooper()).post(() -> result.success(err));
            }
        }).start();
    }

    /** 用 Shizuku 执行 shell 命令并返回完整输出 */
    private Map<String, Object> execShell(String command) {
        Map<String, Object> out = new HashMap<>();
        try {
            Method newProcess = Shizuku.class.getDeclaredMethod(
                    "newProcess", String[].class, String[].class, String.class);
            newProcess.setAccessible(true);
            Process process = (Process) newProcess.invoke(null,
                    new String[]{"sh", "-c", command}, null, null);
            if (process == null) {
                out.put("exitCode", -3);
                out.put("stdout", "");
                out.put("stderr", "Shizuku.newProcess 返回 null");
                return out;
            }

            StringBuilder stdout = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(process.getInputStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    stdout.append(line).append("\n");
                }
            }

            StringBuilder stderr = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(process.getErrorStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    stderr.append(line).append("\n");
                }
            }

            out.put("exitCode", process.waitFor());
            out.put("stdout", stdout.toString());
            out.put("stderr", stderr.toString());
            return out;
        } catch (Exception e) {
            out.put("exitCode", -4);
            out.put("stdout", "");
            out.put("stderr", "execShell异常: " + e.getClass().getSimpleName() + ": " + e.getMessage());
            return out;
        }
    }

    /** 多策略 Shizuku 删除 */
    private Map<String, Object> deletePathViaShizuku(String path) {
        // 策略 1: rm -rf (标准)
        Map<String, Object> r1 = execShell("rm -rf '" + path + "'");
        if (r1.get("exitCode") != null && ((Number)r1.get("exitCode")).intValue() == 0) {
            // 验证是否真的删除成功
            Map<String, Object> verify = execShell("ls '" + path + "' >/dev/null 2>&1 && echo exists || echo not_found");
            String vout = verify.get("stdout") != null ? verify.get("stdout").toString().trim() : "";
            if (!"exists".equals(vout)) {
                r1.put("success", true);
                return r1;
            }
            // rm 返回 0 但目录仍在 — 走策略 2
        }

        // 策略 2: 先清空内容再删目录 (find -delete)
        Map<String, Object> r2 = execShell(
            "find '" + path + "' -type f -delete 2>/dev/null; " +
            "find '" + path + "' -depth -type d -exec rmdir {} \\; 2>/dev/null; " +
            "rm -rf '" + path + "' 2>/dev/null; " +
            "ls '" + path + "' >/dev/null 2>&1 && echo still_exists || echo deleted"
        );
        String r2out = r2.get("stdout") != null ? r2.get("stdout").toString().trim() : "";
        if (!"still_exists".equals(r2out)) {
            r2.put("success", true);
            return r2;
        }

        // 策略 3: 尝试用 toolbox 的 rm (有些设备上 toolbox 比 toybox 有更高权限)
        Map<String, Object> r3 = execShell(
            "/system/bin/toolbox rm -rf '" + path + "' 2>&1; " +
            "ls '" + path + "' >/dev/null 2>&1 && echo still_exists || echo deleted"
        );
        String r3out = r3.get("stdout") != null ? r3.get("stdout").toString().trim() : "";
        if (!"still_exists".equals(r3out)) {
            r3.put("success", true);
            return r3;
        }

        // 全部失败 — 返回最后的错误信息
        Map<String, Object> failed = new HashMap<>();
        failed.put("success", false);
        failed.put("exitCode", r3.get("exitCode"));
        failed.put("stdout", r3.get("stdout"));
        failed.put("stderr", r3.get("stderr"));
        // 附加三个策略的汇总
        String detail = "策略1 rm: exit=" + r1.get("exitCode") + " stderr=" + r1.get("stderr")
                      + " | 策略2 find: exit=" + r2.get("exitCode") + " stderr=" + r2.get("stderr")
                      + " | 策略3 toolbox: exit=" + r3.get("exitCode") + " stderr=" + r3.get("stderr");
        failed.put("detail", detail);
        return failed;
    }

    // ─── 打开文件夹（系统选择器） ────────────────────────

    /** 通过 Android Intent 打开文件夹，系统会弹出 App 选择器 */
    private void handleOpenFolder(MethodCall call, Result result) {
        String folderPath = call.argument("path");
        if (folderPath == null || folderPath.isEmpty()) {
            result.success(false);
            return;
        }
        if (activity == null) {
            result.success(false);
            return;
        }
        try {
            // 使用 Android Intent 打开文件夹
            java.io.File folder = new java.io.File(folderPath);
            android.net.Uri uri;
            // Android 11+ 推荐使用 DocumentFile 方式
            // 但直接用 file:// URI + ACTION_VIEW 也能触发系统选择器
            uri = android.net.Uri.fromFile(folder);
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(uri, "resource/folder");
            // 关键：不指定具体包名，让系统弹出选择器让用户选
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            // 给所有能处理的应用一个临时读权限
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            activity.startActivity(Intent.createChooser(intent, "选择文件管理器"));
            result.success(true);
        } catch (Exception e) {
            // 上述方式可能不兼容所有设备，回退到更通用的方式
            try {
                android.net.Uri fallbackUri = android.net.Uri.parse("file://" + folderPath);
                Intent fallbackIntent = new Intent(Intent.ACTION_VIEW);
                fallbackIntent.setDataAndType(fallbackUri, "resource/folder");
                fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                activity.startActivity(Intent.createChooser(fallbackIntent, "选择文件管理器"));
                result.success(true);
            } catch (Exception e2) {
                result.success(false);
            }
        }
    }

    // ─── SAF 删除（实验性） ───────────────────────────────

    /** 通过 SAF ContentProvider 删除目录（不走 shell，避免 SELinux 封锁）
     *
     * 尝试两种路径：
     *   1. DocumentsContract.deleteDocument() — Java ContentResolver API
     *   2. content delete shell 命令 — 通过 Shizuku 跑 ContentProvider
     *
     * result map: {success: bool, method: String, attempts: Map}
     */
    private void handleDeleteViaSaf(MethodCall call, Result result) {
        String path = call.argument("path");
        if (path == null || path.isEmpty()) {
            Map<String, Object> err = new HashMap<>();
            err.put("success", false);
            err.put("error", "路径为空");
            result.success(err);
            return;
        }

        new Thread(() -> {
            Map<String, Object> out = new HashMap<>();
            Map<String, Object> attempts = new HashMap<>();

            // 构建 Document URI: path → content:// URI
            // /storage/emulated/0/Android/data/... → content://com.android.externalstorage.documents/document/primary%3A...
            String relativePath = path.startsWith("/storage/emulated/0/")
                ? path.substring("/storage/emulated/0/".length())
                : path;

            // ─── 尝试 1: DocumentsContract.deleteDocument() ───
            try {
                Uri docUri = DocumentsContract.buildDocumentUri(
                    "com.android.externalstorage.documents",
                    "primary:" + relativePath
                );
                boolean deleted = DocumentsContract.deleteDocument(
                    context.getContentResolver(), docUri);
                if (deleted) {
                    out.put("success", true);
                    out.put("method", "DocumentsContract.deleteDocument");
                    out.put("attempts", attempts);
                    new Handler(Looper.getMainLooper()).post(() -> result.success(out));
                    return;
                }
                attempts.put("docContract", "返回 false，目录未删除");
            } catch (SecurityException e) {
                attempts.put("docContract", "SecurityException: " + e.getMessage());
            } catch (IllegalArgumentException e) {
                attempts.put("docContract", "IllegalArg: " + e.getMessage());
            } catch (Exception e) {
                attempts.put("docContract", e.getClass().getSimpleName() + ": " + e.getMessage());
            }

            // ─── 尝试 2: content delete shell (via Shizuku) ───
            // content 命令走 ContentProvider binder，不走文件系统
            try {
                // 构造 URI 字符串：手动编码 / 为 %2F
                // DocumentsContract URI 格式: primary%3AAndroid%2Fdata%2F...
                String encodedRelative = Uri.encode(relativePath);
                String contentUriStr = "content://com.android.externalstorage.documents"
                    + "/document/primary%3A" + encodedRelative;

                Map<String, Object> shellOut = execShell(
                    "content delete --uri '" + contentUriStr + "' 2>&1");
                int exitCode = shellOut.get("exitCode") != null
                    ? ((Number) shellOut.get("exitCode")).intValue() : -1;
                String stdout = shellOut.get("stdout") != null
                    ? shellOut.get("stdout").toString() : "";
                String stderr = shellOut.get("stderr") != null
                    ? shellOut.get("stderr").toString() : "";

                // 验证：目录是否真的消失了
                Map<String, Object> verify = execShell(
                    "ls '" + path + "' >/dev/null 2>&1 && echo exists || echo not_found");
                String vout = verify.get("stdout") != null
                    ? verify.get("stdout").toString().trim() : "";

                boolean removed = exitCode == 0 && !"exists".equals(vout);
                if (removed) {
                    out.put("success", true);
                    out.put("method", "content delete shell");
                    attempts.put("contentShell", "OK");
                    out.put("attempts", attempts);
                    new Handler(Looper.getMainLooper()).post(() -> result.success(out));
                    return;
                }
                attempts.put("contentShell", "exit=" + exitCode
                    + " stdout=" + stdout
                    + " stderr=" + stderr
                    + " verify=" + vout);
            } catch (Exception e) {
                attempts.put("contentShell", e.getClass().getSimpleName() + ": " + e.getMessage());
            }

            // ─── 尝试 3: rm -rf via Shizuku (hail mary) ───
            try {
                Map<String, Object> rmOut = execShell("rm -rf '" + path + "' 2>&1");
                Map<String, Object> verify = execShell(
                    "ls '" + path + "' >/dev/null 2>&1 && echo exists || echo not_found");
                String vout = verify.get("stdout") != null
                    ? verify.get("stdout").toString().trim() : "";
                if (!"exists".equals(vout)) {
                    out.put("success", true);
                    out.put("method", "rm -rf via Shizuku");
                    attempts.put("rmrf", "OK (after docContract & contentShell failed)");
                    out.put("attempts", attempts);
                    new Handler(Looper.getMainLooper()).post(() -> result.success(out));
                    return;
                }
                attempts.put("rmrf", "exit=" + rmOut.get("exitCode") + " verify=" + vout);
            } catch (Exception e) {
                attempts.put("rmrf", e.getClass().getSimpleName() + ": " + e.getMessage());
            }

            // ─── 尝试 4: mv 移出 Android/data 再删 ─────────
            // SELinux 对 rename() 的检查可能不同于 unlink/rmdir.
            // 如果 mv 成功将文件夹移到 Download 目录，就可以直接删除。
            try {
                String trashDir = "/storage/emulated/0/Download/Bilimerge/trash";
                // 从路径提取 avid 文件夹名（最后一个路径段）
                String pathTrimmed = path.endsWith("/") ? path.substring(0, path.length() - 1) : path;
                String folderName = pathTrimmed.substring(pathTrimmed.lastIndexOf("/") + 1);
                String trashPath = trashDir + "/" + folderName;

                // 先清理 trash 目录下的同名文件夹
                execShell("rm -rf '" + trashPath + "' 2>/dev/null");
                execShell("mkdir -p '" + trashDir + "' 2>/dev/null");

                // mv 操作：在同一分区上是 rename()，不走文件读写权限
                Map<String, Object> mvOut = execShell(
                    "mv '" + pathTrimmed + "' '" + trashPath + "' 2>&1");
                int mvExit = mvOut.get("exitCode") != null
                    ? ((Number) mvOut.get("exitCode")).intValue() : -1;

                Map<String, Object> verify = execShell(
                    "ls '" + trashPath + "' >/dev/null 2>&1 && echo exists || echo not_found");
                String vout = verify.get("stdout") != null
                    ? verify.get("stdout").toString().trim() : "";

                if (mvExit == 0 && "exists".equals(vout)) {
                    // mv 成功 → 从 trash 删除（我们有权访问 Download 目录）
                    Map<String, Object> delOut = execShell("rm -rf '" + trashPath + "' 2>&1");
                    out.put("success", true);
                    out.put("method", "mv + rm");
                    attempts.put("mvDel", "mv exit=" + mvExit + " trashVerify=" + vout
                        + " rm exit=" + delOut.get("exitCode"));
                    out.put("attempts", attempts);
                    new Handler(Looper.getMainLooper()).post(() -> result.success(out));
                    return;
                }
                attempts.put("mvDel",
                    "mv exit=" + mvExit + " verify=" + vout
                    + " stderr=" + mvOut.get("stderr"));
            } catch (Exception e) {
                attempts.put("mvDel", e.getClass().getSimpleName() + ": " + e.getMessage());
            }

            // 全部失败
            out.put("success", false);
            out.put("method", "all_failed");
            out.put("attempts", attempts);
            new Handler(Looper.getMainLooper()).post(() -> result.success(out));
        }).start();
    }

    // ─── MediaMuxer 合并 ────────────────────────────────

    private void handleMerge(MethodCall call, Result result) {
        String videoPath = call.argument("videoPath");
        String audioPath = call.argument("audioPath");
        String outputPath = call.argument("outputPath");
        if (videoPath == null || audioPath == null || outputPath == null) {
            result.error("INVALID_ARGS", "Missing required arguments", null);
            return;
        }
        // 后台线程执行合并（最低优先级，让 UI 线程优先获取 CPU）
        Thread mergeThread = new Thread(() -> {
            try {
                Map<String, Object> mergeResult = mergeAudioVideo(videoPath, audioPath, outputPath);
                new Handler(Looper.getMainLooper()).post(() -> result.success(mergeResult));
            } catch (Exception e) {
                Map<String, Object> response = new HashMap<>();
                response.put("success", false);
                response.put("errorMessage", e.getClass().getSimpleName() + ": " + e.getMessage());
                new Handler(Looper.getMainLooper()).post(() -> result.success(response));
            }
        });
        mergeThread.setPriority(Thread.NORM_PRIORITY);
        mergeThread.start();
    }

    /** 合并音视频，返回 {success, errorMessage, videoReadMs, audioReadMs, muxerStopMs, totalMs} */
    private Map<String, Object> mergeAudioVideo(String videoPath, String audioPath, String outputPath) {
        MediaExtractor videoExtractor = new MediaExtractor();
        MediaExtractor audioExtractor = new MediaExtractor();
        MediaMuxer muxer = null;
        Map<String, Object> result = new HashMap<>();
        long t0 = System.currentTimeMillis();
        try {
            videoExtractor.setDataSource(videoPath);
            audioExtractor.setDataSource(audioPath);

            int videoTrackIndex = -1;
            int audioTrackIndex = -1;
            MediaFormat videoFormat = null;
            MediaFormat audioFormat = null;

            for (int i = 0; i < videoExtractor.getTrackCount(); i++) {
                MediaFormat format = videoExtractor.getTrackFormat(i);
                String mime = format.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("video/")) {
                    videoTrackIndex = i;
                    videoFormat = format;
                    break;
                }
            }

            for (int i = 0; i < audioExtractor.getTrackCount(); i++) {
                MediaFormat format = audioExtractor.getTrackFormat(i);
                String mime = format.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("audio/")) {
                    audioTrackIndex = i;
                    audioFormat = format;
                    break;
                }
            }

            if (videoTrackIndex < 0) {
                result.put("success", false);
                result.put("errorMessage", "未找到视频轨道 (track count=" + videoExtractor.getTrackCount() + ")");
                return result;
            }
            if (audioTrackIndex < 0) {
                result.put("success", false);
                result.put("errorMessage", "未找到音频轨道 (track count=" + audioExtractor.getTrackCount() + ")");
                return result;
            }

            // 日志输出轨道格式信息（debug 时有用）
            String videoMime = videoFormat.getString(MediaFormat.KEY_MIME);
            int videoW = videoFormat.getInteger(MediaFormat.KEY_WIDTH);
            int videoH = videoFormat.getInteger(MediaFormat.KEY_HEIGHT);
            android.util.Log.i("BiliMerge", "视频轨道: " + videoMime + " " + videoW + "x" + videoH);

            muxer = new MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            int muxerVideoTrack = muxer.addTrack(videoFormat);
            int muxerAudioTrack = muxer.addTrack(audioFormat);
            muxer.start();

            videoExtractor.selectTrack(videoTrackIndex);
            ByteBuffer sharedBuf = ByteBuffer.allocateDirect(2 * 1024 * 1024);
            MediaCodec.BufferInfo videoInfo = new MediaCodec.BufferInfo();
            while (true) {
                sharedBuf.clear();
                int sampleSize = videoExtractor.readSampleData(sharedBuf, 0);
                if (sampleSize < 0) break;
                videoInfo.offset = 0;
                videoInfo.size = sampleSize;
                videoInfo.flags = videoExtractor.getSampleFlags();
                videoInfo.presentationTimeUs = videoExtractor.getSampleTime();
                muxer.writeSampleData(muxerVideoTrack, sharedBuf, videoInfo);
                videoExtractor.advance();
            }
            long t1 = System.currentTimeMillis();

            audioExtractor.selectTrack(audioTrackIndex);
            MediaCodec.BufferInfo audioInfo = new MediaCodec.BufferInfo();
            while (true) {
                sharedBuf.clear();
                int sampleSize = audioExtractor.readSampleData(sharedBuf, 0);
                if (sampleSize < 0) break;
                audioInfo.offset = 0;
                audioInfo.size = sampleSize;
                audioInfo.flags = audioExtractor.getSampleFlags();
                audioInfo.presentationTimeUs = audioExtractor.getSampleTime();
                muxer.writeSampleData(muxerAudioTrack, sharedBuf, audioInfo);
                audioExtractor.advance();
            }
            long t2 = System.currentTimeMillis();

            muxer.stop();
            long t3 = System.currentTimeMillis();

            result.put("success", true);
            result.put("errorMessage", null);
            result.put("videoReadMs", t1 - t0);
            result.put("audioReadMs", t2 - t1);
            result.put("muxerStopMs", t3 - t2);
            result.put("totalMs", t3 - t0);
            return result;
        } catch (java.nio.BufferOverflowException e) {
            result.put("success", false);
            result.put("errorMessage", "BufferOverflow: 采样超过2MB限制");
            return result;
        } catch (MediaCodec.CodecException e) {
            result.put("success", false);
            result.put("errorMessage", "Codec异常: " + e.getDiagnosticInfo() + " (" + e.getMessage() + ")");
            return result;
        } catch (Exception e) {
            result.put("success", false);
            result.put("errorMessage", e.getClass().getSimpleName() + ": " + e.getMessage());
            return result;
        } finally {
            try { videoExtractor.release(); } catch (Exception ignored) {}
            try { audioExtractor.release(); } catch (Exception ignored) {}
            try { if (muxer != null) muxer.release(); } catch (Exception ignored) {}
        }
    }

    // ─── SAF 复制 ───────────────────────────────────────

    private void handleCopyFromSaf(MethodCall call, Result result) {
        String safUri = call.argument("safUri");
        String destPath = call.argument("destPath");
        if (safUri == null || destPath == null) {
            result.error("INVALID_ARGS", "Missing safUri or destPath", null);
            return;
        }
        try {
            int count = copyFromSafUri(safUri, destPath);
            if (count > 0) {
                result.success(count);
            } else {
                result.error("COPY_FAILED", "No media files found", null);
            }
        } catch (Exception e) {
            result.error("COPY_ERROR", e.getMessage(), null);
        }
    }

    private int copyFromSafUri(String safUri, String destPath) throws IOException {
        Uri treeUri = Uri.parse(safUri);
        final int takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION;
        context.getContentResolver().takePersistableUriPermission(treeUri, takeFlags);
        File destRoot = new File(destPath);
        destRoot.mkdirs();
        int[] mediaCount = new int[]{0};
        copyDocumentTree(treeUri, destRoot, mediaCount);
        return mediaCount[0];
    }

    private void copyDocumentTree(Uri dirUri, File destDir, int[] mediaCount) throws IOException {
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(dirUri,
                DocumentsContract.getDocumentId(dirUri));
        String[] projection = {DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE};

        boolean hasVideo = false;
        boolean hasAudio = false;
        Uri videoFileUri = null;
        Uri audioFileUri = null;
        java.util.List<Uri> subDirs = new java.util.ArrayList<>();
        java.util.List<Uri> miscFiles = new java.util.ArrayList<>();

        try (android.database.Cursor cursor = context.getContentResolver().query(
                childrenUri, projection, null, null, null)) {
            if (cursor != null) {
                while (cursor.moveToNext()) {
                    String docId = cursor.getString(0);
                    String name = cursor.getString(1);
                    String mime = cursor.getString(2);
                    Uri childUri = DocumentsContract.buildDocumentUriUsingTree(dirUri, docId);

                    if (DocumentsContract.Document.MIME_TYPE_DIR.equals(mime)) {
                        subDirs.add(childUri);
                    } else {
                        if ("video.m4s".equals(name)) {
                            hasVideo = true;
                            videoFileUri = childUri;
                        } else if ("audio.m4s".equals(name)) {
                            hasAudio = true;
                            audioFileUri = childUri;
                        } else if ("entry.json".equals(name) || "cover.jpg".equals(name) || "index.json".equals(name)) {
                            miscFiles.add(childUri);
                        }
                    }
                }
            }
        }

        if (hasVideo && hasAudio) {
            destDir.mkdirs();
            if (videoFileUri != null) copyFile(videoFileUri, new File(destDir, "video.m4s"));
            if (audioFileUri != null) copyFile(audioFileUri, new File(destDir, "audio.m4s"));
            for (Uri mf : miscFiles) {
                String displayName = getDisplayName(mf);
                copyFile(mf, new File(destDir, displayName != null ? displayName : "unknown"));
            }
            mediaCount[0]++;
        }

        for (Uri mf : miscFiles) {
            String displayName = getDisplayName(mf);
            if (displayName != null && ("entry.json".equals(displayName) || "cover.jpg".equals(displayName))) {
                File target = new File(destDir, displayName);
                if (!target.exists()) {
                    copyFile(mf, target);
                }
            }
        }

        for (Uri sub : subDirs) {
            String subName = getDisplayName(sub);
            if (subName == null) continue;
            copyDocumentTree(sub, new File(destDir, subName), mediaCount);
        }
    }

    private String getDisplayName(Uri uri) {
        String[] projection = {DocumentsContract.Document.COLUMN_DISPLAY_NAME};
        try (android.database.Cursor cursor = context.getContentResolver().query(
                uri, projection, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                return cursor.getString(0);
            }
        } catch (Exception ignored) {}
        return null;
    }

    private void copyFile(Uri sourceUri, File destFile) throws IOException {
        destFile.getParentFile().mkdirs();
        try (InputStream in = context.getContentResolver().openInputStream(sourceUri);
             OutputStream out = new FileOutputStream(destFile)) {
            if (in == null) throw new IOException("Cannot open input stream for " + sourceUri);
            byte[] buf = new byte[64 * 1024];
            int len;
            while ((len = in.read(buf)) > 0) {
                out.write(buf, 0, len);
            }
        }
    }
}