# M04P4 自研 FFmpeg 内核的依赖底座（Libav 探针）

- 状态：**已实现**（本地静态闸门全绿 + 新单测；Mac 编译与实测待 YG）
- 时间：2026-10-10
- 触发：M4 的口径是「**主做 HDR 与流畅度**」（README），而自研内核**必须**直接调 Libav*。
  MPVKit 声称同时提供 libmpv 与 FFmpeg 七件套（`ThirdParty/mpvkit.lock.json`），
  但之前唯一的探针 `MpvAvailability.canImportLibavcodec` 只回答「能不能 `import`」——
  不回答「能不能链接、版本是多少、字幕库在不在」。写引擎第一行之前，先把这几件事钉死。

## 一、探针：六个模块，两道关

新增 `FFmpegAvailability`（镜像 `MpvAvailability` 的套路，只探引擎真会用的）：

| 模块 | 引擎拿它干什么 |
| --- | --- |
| Libavformat | demux（含自定义 AVIO / HTTP 头注入） |
| Libavcodec | 解码（VideoToolbox 硬解与软解都是它） |
| Libavutil | 基础（AVFrame / AVDictionary / 时间基） |
| Libswscale | 软解路径的像素转换 |
| Libswresample | 音频重采样 / 采样格式归一 |
| Libass | 字幕上屏（M03 方案定的字幕路线） |

两道关，缺一不可：

1. **编译期**：`#if canImport(...)` —— 模块在不在搜索路径里；
2. **运行期**：真调一下 `avcodec_version()` / `avformat_version()` / `avutil_version()` /
   `swscale_version()` / `swresample_version()` 读版本号 —— 「能 import」可能只是头文件在，
   链接不上照样是空的。（Libass 只报可用性：版本号编码没核实过，**不猜**。）

探针结果进两处用户能看见的地方：

- 诊断报告「【播放】」段新增一行「自研内核：…」（`FFmpegAvailability.summary`）；
- `.ffmpeg` 的「不可用原因」跟着事实走：缺依赖报**缺哪个**，依赖齐就直说「引擎尚未实装」。

## 二、口径：依赖就绪 ≠ 能用（与 MPV 同一条纪律）

- `FFmpegAvailability.isEngineImplemented = false`：引擎没接进 `PlayerCoordinator` 的创建路径前，
  `.ffmpeg` 的 `isAvailable` 始终 false —— 不因为「依赖连上了」就宣称能用（M03P1 踩过的坑）；
- `MpvAvailability.summary` 顺手改了：以前它混着报 Libavcodec；现在只讲 libmpv 与 MPV 引擎自身，
  并把「引擎实装 / 画面路径」两个事实都写出来（以前只写「libmpv=可用」，看不出为什么不可用）；
- 依赖事实的归属收敛为两处：`MpvAvailability`（libmpv）与 `FFmpegAvailability`（Libav*），
  别处不再直接 `canImport`。

## 三、故意没做

- **不写引擎骨架 / 会话分层**：`FFmpegSession` 这类 seam 要按真实的 demux 循环来切，
  现在动笔就是猜接口 —— 等这轮探针结果（模块齐不齐、版本号多少）回来再定；
- 不探 Libavfilter / Libavdevice：引擎不用（HDR 色调映射计划走 Metal 侧），探针也得有人消费；
- 不报 Libass 版本号：编码格式没核实过，宁可空着。

## 四、验证点（Mac）

1. `swift test --package-path Packages/CatVodPlayer` 全绿 —— 六模块 import、五个版本号、
   原因分支都在新套件 `FFmpegAvailabilityTests` 里；
2. 若哪个模块红：**别改期望值**，把失败信息原样发回 —— 那正是 M4 要面对的真问题；
3. 设置 → 日志管理 → 诊断 →「复制诊断信息」：应有「自研内核：Libav 6/6：…」一行，
   把这一行发回（版本号决定 M4 的 API 基线）。
