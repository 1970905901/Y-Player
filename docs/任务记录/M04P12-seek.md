# M04P12 seek（跳转 + 起点续播）

- 状态：**已实现**（本地静态闸门全绿 + 新单测；Mac 编译与测试待 YG）
- 时间：2026-10-10
- 触发：M04P11 音视频闭环就位。seek 是接线进 UI 前**最后一个**功能缺口。

## 一、做法

1. **跳转请求走解码线程消费**：控制线程（`seek(to:)`）只把目标放进 `pendingSeek`
   + **立刻回执**一条 `.time`（UI 不等内核往返）；解码线程每轮先取请求、真跳。
   一段读包的人只能有一个 —— 这是 M04P10 定的规矩。
2. **`LibavInput.seek`**：`av_seek_frame(streamIndex = -1, 微秒时间戳, AVSEEK_FLAG_BACKWARD)`
   → 跳到目标**之前**最近的关键帧（HDR 片常 10 秒一个 I 帧，往前跳才不黑屏等）；
   跳完 `isAtEnd` 复位、读包缓冲丢掉。
3. **两侧解码器 flush**：视频清 B 帧 / 硬解缓冲（不清会吐旧位置的帧）；
   音频连 **swresample 一起清** —— 重采样器里压着几毫秒延迟样本，
   不清会把旧位置的声音带到新位置去。
4. **显示层 reset**：清显示队列 + 时间轴挪到目标秒（保持播放 / 暂停与倍速）。
5. **复播口径**：`startedPlaying` 复位 → 第一帧回来重新报 `.playing`
   （从 `.ended` 跳回来也要能复播）；`endedEmitted` 复位 → 再次读到尾能再次报 `.ended`。
6. **起点续播**：`startPosition` 就是「打开后先跳一次」—— 输入跳到那、时间轴也停在
   目标秒（`playing: false`），第一帧回来自然开播。

## 二、口径与已知取舍

- 跳的是目标**之前**的关键帧：跳完会从关键帧开始吐帧，早于目标的那点帧由时间轴自然丢掉。
  v1 接受这个口径（精确 seek 到帧是后面的事）；
- seek 立刻回执的是**目标时间**，不是实际落点（落点由关键帧决定，可能更早）。

## 三、故意没做

- 软解；音轨切换；UI 接线（`FFmpegVideoView` + PlaybackView 分支）——
  **availability 仍 false**，等接线上机能播能听再翻。

## 四、验证点（Mac）

1. `swift test --package-path Packages/CatVodPlayer`：
   - 「Libav 输入层」+1：读到尾 → `seek(0)` → `isAtEnd` 复位 → 还能再读满一遍；
   - 「FFmpeg 真会话」+1：播到结束 → `seek(0)` → 回执立刻有、解码线程清队重定位
     （`reset(to: 0, playing: true, rate: 1)`）→ 重新读回、**第二次** `.ended` 报到；
2. 全包测试 + App 编译照旧；
3. 行为上仍然零变化（`.ffmpeg` 不可选）。
