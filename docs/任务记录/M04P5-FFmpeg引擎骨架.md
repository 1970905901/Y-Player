# M04P5 自研 FFmpeg 引擎骨架（会话 seam + 状态机）

- 状态：**已实现**（本地静态闸门全绿 + 新单测；Mac 编译与测试待 YG）
- 时间：2026-10-10
- 触发：M04P4 探针确认 Libav 六件套 import / 链接 / 版本全通后，按 M03P1 定的分层开写自研内核。
  用户同日拍板：**继续自研 FFmpeg 路线** —— 中途核实并否决了两条替代路线，结论留档：
  - KSPlayer：免费 GPL 版核心是**二进制**且没有 iOS 真机切片（xcframework 只有 macOS / tvOS /
    iOS 模拟器），真机要付费 LGPL；且它本身就是 AVPlayer+FFmpeg 组合，替代不了「不要自写 FFmpeg」的诉求。
  - VLC（MobileVLCKit）：真机可用，但 libVLC 内置 FFmpeg，与现有 MPV 内核能力高度重叠；
    3.x 的 iOS 渲染还是 OpenGL ES（没有 HDR 输出），4.0 至今只有 alpha / unstable 构建。

## 一、分层（同 MpvEngine，M03P3 的结论直接复用）

| 层 | 文件 | 内容 |
| --- | --- | --- |
| 引擎（语义） | `FFmpegEngine`（actor） | `PlayerEngine` 的实现：加载 / 命令 / 状态 / 事件 / 播放信息；用假会话在 CI 上单测 |
| seam | `FFmpegSession` + `FFmpegSessionEvent` | 与真管线的边界：open / play / pause / seek / rate / volume / selectTrack / stats / close / events |
| 真会话 | （M04P6 起） | demux / 解码 / 渲染 / 音频；**全工程唯一的 libav 调用点** |

## 二、三条口径

1. **状态以会话事件为准**（会话知道自己在缓冲还是真的在播）：引擎只在 `open` 成功后发 `.loading`，
   会话不重复报；`seek` / `setRate` 的回执由引擎立刻补发（UI 不等内核往返，对齐 MPV 的手感）。
2. **可用性照旧收紧**：`FFmpegAvailability.isEngineImplemented` 仍为 false、`PlayerCoordinator`
   仍不创建本引擎 —— 引擎骨架 ≠ 能出画面（同 MPV 的 `isVideoOutputReady` 纪律）。
   真会话落成 + 渲染 PoC 通过后一起翻。
3. **C 调用不越界**：引擎只对着 seam 编程；真会话把 `avformat` / `avcodec` / … 全部收在自己文件里。

## 三、渲染路径的设计倾向（M04P6 先做 PoC 再定死）

首选：**AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer**。

- 分工：demux / 解码我们自己做，presentation（HDR/EDR 输出、帧调度、A/V 同步、倍速）交给系统渲染管线；
- 理由：M4 的口径是「HDR 与流畅度」，而这正是系统栈的强项（M04P2 的「色彩 / 输出」两行正好验它）；
- 备选（若显示层对某些片源 / HDR 不达标）：VideoToolbox → CAMetalLayer 自绘（M03P1 第 3 步的 MoltenVK 经验）；
- PoC 验证点：HDR 片源在播放信息里「色彩 HDR / 输出 HDR」；4K 60fps 无掉帧。

## 四、故意没做

- **真会话**（libav 调用、demux、解码、音频、渲染）—— M04P6 起，一步一步来；
- 轨道**内容**的枚举：`selectTrack` 已按 `TrackSelection` 下发，但真实轨道 id 要等 demux 认出来；
- 渲染面（`MpvVideoSurface` 的对应物）—— 定显示层路径时再加。

## 五、验证点（Mac）

1. `swift test --package-path Packages/CatVodPlayer`：新套件「FFmpeg 引擎（假会话）」全绿
   （加载 / 命令 / 事件 / 错误路径 / 生命周期都在里面）；
2. 全包测试 + App 编译照旧；
3. 行为空：`.ffmpeg` 仍不可选 —— 设置里应显示「依赖已就绪（Libav 6/6），引擎尚未实装」。
