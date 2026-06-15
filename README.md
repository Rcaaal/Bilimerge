# BiliMerge — B站缓存视频导出工具

合并并导出 B站 Android 客户端缓存的 m4s 音视频文件为 mp4，支持通过 Shizuku 直接访问受 Android/data 保护的目录。

## 功能

- **一键导出**：将 B站缓存中的 `video.m4s` + `audio.m4s` 无重编码合并为 `.mp4`
- **Shizuku 支持**：无需 root，通过 Shizuku 服务直接读取 `/Android/data/tv.danmaku.bili/download/`
- **仅扫描模式**：首次秒开，导出时逐个复制，省空间省时间
- **批量导出**：支持队列批量导出，带进度显示
- **分P处理**：同一视频的多个分P自动视为一体，导出/删除/队列统一管理
- **源文件删除**：导出后自动删除原始缓存文件夹（4 种删除策略兜底）
- **导出历史**：记录所有导出记录，可查看已导出文件和删除源文件夹

## Shizuku 使用方法

BiliMerge 通过 [Shizuku](https://shizuku.rikka.app/) 访问 `Android/data` 目录下的 B站缓存，这是 Android 11+ 系统限制下最便捷的方案。

### 第一步：安装 Shizuku

1. 下载 [Shizuku](https://shizuku.rikka.app/download/) APK 并安装
2. 也可在酷安、Google Play 搜索 "Shizuku" 下载

### 第二步：启动 Shizuku 服务

**有 root 权限：**
- 打开 Shizuku App → 点击「启动」→ 允许 root 权限 → 完成

**无 root 权限（Android 11+）：**

1. 打开 Shizuku App → 点击「配对」
2. 下拉通知栏 → 找到 Shizuku 配对通知 → 记下配对码（6 位数字）
3. 在通知栏输入配对码
4. 回到 Shizuku App → 配对成功后点击「启动」
5. 无线调试配对仅在首次设置时需要，后续打开 App 点击「启动」即可

> ⚠️ 注意：部分手机（如 MIUI/HyperOS、ColorOS）在系统设置中需要开启「USB 调试（安全设置）」才能正常使用无线调试配对。
>
> 详细配对说明参考 [Shizuku 官方文档](https://shizuku.rikka.app/guide/setup/#start-shizuku)

### 第三步：在 BiliMerge 中使用

1. 确保 Shizuku 服务已在运行（Shizuku App 顶部显示「正在运行」）
2. 打开 BiliMerge → 点击右上角菜单 `⋮` → **「加载B站缓存」**
3. 在弹出的 Shizuku 授权对话框中点击「授权」
4. 选择读取模式：
   - **仅扫描（推荐）**：只读取视频列表和封面，首次秒开，导出时逐个复制
   - **全量复制**：复制全部缓存到临时目录，导出快，但首次需等待

### 常见问题

**Shizuku 已安装但服务未启动？**
→ App 中会显示启动引导，按提示操作后点「已启动，重试」

**没有 Shizuku？**
→ 可以使用 MT 管理器或其他文件管理器手动复制缓存目录到 `/Download/BiliMerge/`，然后在 App 中选择该目录

## 下载

前往 [Releases](https://github.com/Rcaaal/Bilimerge/releases) 页面下载最新 APK。

## 构建

```bash
./build_apk.sh debug        # Debug 版
./build_apk.sh release       # Release 版（需配置签名）
```

## 技术栈

- **Flutter** — 跨平台 UI 框架
- **FFmpeg**（`ffmpeg-kit`）— 音视频无重编码合并（`-c copy`）
- **Shizuku API** — 直接访问受保护目录
- **SAF / DocumentsContract** — 文件操作兜底策略

## License

MIT
