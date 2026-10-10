import AVFoundation
import Foundation

/// 自研 FFmpeg 内核的**真实会话**（M04P14 起：音视频 + seek + 软解兜底都接上）：
/// 统一 demux（`LibavInput.nextPacket`）→ 视频走解码器进显示层（**按设置的解码方式：硬解 / 软解，不自动降级**）、
/// 音频走 libavcodec + swresample 进音频渲染器；两者挂**同一条** synchronizer。
///
/// 当前已知缺口（**如实说，别让界面以为它全能**；M04P13 已把它接进界面）：
/// - **音轨切换**：`selectTrack` 是空操作（只有默认轨）；
/// - 网络读阻塞期间 `close()` 不保证立刻收线程 —— 在没有 interrupt callback 之前，
///   宁可让线程自然退出，也不释放它可能正在读的上下文；
/// - `stats()` 里画面那几行是**打开时读到的事实**（分辨率 / 编码 / 容器），不是 mpv 那种逐帧快照；
///   「解码」那行例外 —— 它是第一帧实测出来的（硬解还是软解）。
///
/// 分层：C 调用全在 `LibavInput` / 两个解码器 / 两个渲染器里，本类只管
/// 线程、状态与背压。一个会话只服务一次打开（引擎换片会新建会话）。
final class LibavFFmpegSession: FFmpegSession, @unchecked Sendable {
    private let input = LibavInput()
    private let videoDecoder = LibavVideoDecoder()
    /// 没有音轨的文件就一直是 nil（不是错误）。
    private var audioDecoder: LibavAudioDecoder?
    private let videoRenderer: any FFmpegVideoRendering
    private let audioRenderer: any FFmpegAudioRendering
    let events: AsyncStream<FFmpegSessionEvent>
    private let continuation: AsyncStream<FFmpegSessionEvent>.Continuation?

    private let lock = NSLock()
    private var running = false
    private var decodeFinished = false
    private var playing = false
    private var rate: Float = 1
    private var endedEmitted = false
    /// 待办的跳转请求（控制线程放、解码线程取 —— 一段读包的人只能有一个）。
    private var pendingSeek: Double?
    private var durationSeconds: Double = 0
    private var info: LibavInput.MediaInfo?

    // 以下只在解码线程里碰：不需要锁
    private var startedPlaying = false
    private var pendingFrame: LibavVideoDecoder.Frame?
    private var lastFrameDelta = 1.0 / 30
    private var lastEmittedSeconds = -10.0
    private var finishedEof = false

    /// 排障计数（M04P13 起，**只在解码线程里读写**）：两侧各喂进去多少、开跑多久。
    /// 「有声音没画面」的判断就靠它们（见 `reportVideoSilenceIfNeeded()`）。
    private var routedVideoPackets = 0
    private var videoFramesAccepted = 0
    private var audioSamplesEnqueued = 0
    private var loopStartedAt = Date()
    private var loggedVideoSilence = false
    /// 实际跑起来的解码路径（第一帧定）：解码线程写、控制路径（`stats()`）读 —— 用 `lock` 串。
    private var actualDecodeIsHardware: Bool?
    private var reportedHardwareFallback = false

    /// 生产入口：给画面层 —— 音视频挂**同一条** synchronizer（音画同步结构自带）。
    ///
    /// `convenience`：类的 designated init **不能** `self.init` 委派（actor 那套写法不能照搬，
    /// M04P9 首轮编译就是红在这）。
    convenience init(surface: FFmpegVideoSurface) {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        self.init(
            videoRenderer: LibavVideoRenderer(surface: surface, synchronizer: synchronizer),
            audioRenderer: LibavAudioRenderer(synchronizer: synchronizer)
        )
    }

    /// 单测入口：给假渲染器（真输入 / 真解码仍会跑 —— 集成测试的用法）。
    init(videoRenderer: any FFmpegVideoRendering, audioRenderer: any FFmpegAudioRendering) {
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        var captured: AsyncStream<FFmpegSessionEvent>.Continuation?
        events = AsyncStream<FFmpegSessionEvent> { captured = $0 }
        continuation = captured
    }

    // MARK: - FFmpegSession

    func open(_ resource: MediaResource, decoderMode: DecoderMode) async -> String? {
        if let failure = input.open(url: resource.url, headers: resource.headers) {
            return failure
        }
        if let failure = videoDecoder.open(input: input, decoderMode: decoderMode) {
            return failure
        }
        // 有音轨就得能解：解不了直接报错，不悄悄变成默片
        if input.firstStreamIndex(of: .audio) != nil {
            let decoder = LibavAudioDecoder()
            if let failure = decoder.open(input: input) {
                decoder.close()
                videoDecoder.close()
                input.close()
                return failure
            }
            audioDecoder = decoder
        }
        info = input.mediaInfo()
        durationSeconds = info?.durationSeconds ?? 0
        // 起点续播就是「打开后先跳一次」：时间轴也挪过去，等第一帧回来自然开播。
        if resource.startPosition > 0 {
            if let failure = input.seek(to: resource.startPosition) {
                videoDecoder.close()
                audioDecoder?.close()
                input.close()
                return failure
            }
            videoRenderer.reset(to: resource.startPosition, playing: false, rate: 1)
        }
        let video = info?.streams.first { $0.kind == .video }
        let audio = info?.streams.first { $0.kind == .audio }
        let opened = "会话打开：视频=\(video?.codecName ?? "无") 音频=\(audio?.codecName ?? "无") "
            + "时长=\(durationSeconds)s 起点=\(resource.startPosition)s"
        LibavTrace.logger.notice("\(opened, privacy: .public)")
        loopStartedAt = Date()
        startDecodeLoop()
        return nil
    }

    func play() async {
        lock.lock()
        playing = true
        let rate = rate
        lock.unlock()
        videoRenderer.play(rate: rate)
        emit(.state(.playing))
    }

    func pause() async {
        lock.lock()
        playing = false
        lock.unlock()
        videoRenderer.pause()
        emit(.state(.paused))
    }

    func seek(to seconds: Double) async {
        let target = max(seconds, 0)
        lock.lock()
        pendingSeek = target
        lock.unlock()
        // 立刻回执：UI 不等内核往返；真正的跳转由解码线程做（见 `performSeek`）。
        emit(.time(current: target, duration: durationSeconds))
    }

    func setRate(_ rate: Float) async {
        lock.lock()
        self.rate = rate
        let playing = playing
        lock.unlock()
        if playing {
            videoRenderer.play(rate: rate)
        }
    }

    /// 音量（0...1）：透传给音频渲染器。
    func setVolume(_ volume: Float) async {
        audioRenderer.setVolume(min(max(volume, 0), 1))
    }

    func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        // 轨道选择还没做：现在都只有默认轨。
        _ = selection
        _ = kind
    }

    func stats() async -> PlaybackStats {
        guard let info else {
            return PlaybackStats()
        }
        var raw: [String: String] = [:]
        if let video = info.streams.first(where: { $0.kind == .video }) {
            raw["video-params/w"] = String(video.width)
            raw["video-params/h"] = String(video.height)
            raw["video-format"] = video.codecName
        }
        if let audio = info.streams.first(where: { $0.kind == .audio }) {
            raw["audio-codec"] = audio.codecName
        }
        if !info.containerName.isEmpty {
            raw["file-format"] = info.containerName
        }
        // 「解码」那行说实话：实际拿到的是哪种帧（硬解不可用时 libav 会自己掉回软解）。
        // 一帧都还没到就先不写 —— 宁可这行空着，也不猜。
        lock.lock()
        let isHardware = actualDecodeIsHardware
        lock.unlock()
        if let isHardware {
            raw["hwdec-current"] = isHardware ? "videotoolbox" : "no"
        }
        return PlaybackStats(rawValues: raw)
    }

    func close() async {
        lock.lock()
        running = false
        lock.unlock()
        // 等解码线程自己退出。没有 interrupt callback 之前**不能**释放
        // 它可能正在读的上下文 —— 本地文件毫秒级退出；网络卡住就让它自己收尾。
        for _ in 0 ..< 20 {
            if isDecodeFinished() {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if isDecodeFinished() {
            videoDecoder.close()
            audioDecoder?.close()
            input.close()
        }
        continuation?.finish()
    }

    // MARK: - 解码线程

    private func startDecodeLoop() {
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.decodeLoop() }
        thread.name = "yplayer-ffmpeg-decode"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// 解码主循环：背压等 → 取包 → 按流分发给两个解码器 → 喂对应的渲染器。
    private func decodeLoop() {
        defer { markDecodeFinished() }
        while isRunning() {
            if let target = takePendingSeek() {
                performSeek(to: target)
                continue
            }
            if finishedEof {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard renderersReady() else {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            guard let packet = input.nextPacket() else {
                if input.isAtEnd {
                    finishStream()
                } else {
                    // 读包失败但不是 EOF（网络抖动 / 超时）：抖一抖再试
                    Thread.sleep(forTimeInterval: 0.01)
                }
                continue
            }
            route(packet)
            if videoDecoder.hardwareFallbackDetected {
                failHardwareFallback()
                continue
            }
            emitTimeIfNeeded()
            reportVideoSilenceIfNeeded()
        }
    }

    /// 真正跳转（**只在解码线程里跑**）：输入跳关键帧 → 两侧解码器 flush →
    /// 丢 pending 视频帧 → 时间轴重定位（清显示队列 + 挪到目标秒）。
    ///
    /// 注意跳的是**目标之前的关键帧**（`AVSEEK_FLAG_BACKWARD`）：跳完会从关键帧开始吐帧，
    /// 早于目标的那点帧由显示层按时间轴自然丢掉。
    private func performSeek(to seconds: Double) {
        if let failure = input.seek(to: seconds) {
            emit(.state(.failed(failure)))
            return
        }
        videoDecoder.flush()
        audioDecoder?.flush()
        pendingFrame = nil
        finishedEof = false
        // 第一帧回来后重新报 .playing：从 .ended 跳回来也要能复播。
        startedPlaying = false
        lock.lock()
        endedEmitted = false
        let playing = playing
        let rate = rate
        lock.unlock()
        lastEmittedSeconds = seconds
        videoRenderer.reset(to: seconds, playing: playing, rate: rate)
        audioRenderer.flush()
    }

    /// 取走待办跳转（解码线程消费；控制线程只放不快取）。
    private func takePendingSeek() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let target = pendingSeek
        pendingSeek = nil
        return target
    }

    /// 背压：有音轨时两侧都要吃得住；只有画面的文件不看音频侧。
    private func renderersReady() -> Bool {
        guard videoRenderer.isReadyForMoreMediaData else { return false }
        if audioDecoder != nil, !audioRenderer.isReadyForMoreMediaData {
            return false
        }
        return true
    }

    /// 按流下标分发（只会命中两条被打开的流；其它流的包直接丢）。
    private func route(_ packet: LibavInput.Packet) {
        if packet.streamIndex == videoDecoder.streamIndex {
            routedVideoPackets += 1
            for frame in videoDecoder.feed(packet.pointer) {
                consume(frame)
            }
            return
        }
        if let audioDecoder, packet.streamIndex == audioDecoder.streamIndex {
            for sample in audioDecoder.feed(packet.pointer) {
                audioRenderer.enqueue(sample)
                audioSamplesEnqueued += 1
            }
        }
    }

    /// 读到尾：两边都冲一次解码器，收干净再报结束。
    private func finishStream() {
        finishedEof = true
        for frame in videoDecoder.drain() {
            consume(frame)
        }
        finishPendingFrame()
        if let audioDecoder {
            for sample in audioDecoder.drain() {
                audioRenderer.enqueue(sample)
                audioSamplesEnqueued += 1
            }
        }
        let summary = "读到尾：视频包=\(routedVideoPackets) 帧入层=\(videoFramesAccepted) "
            + "硬解帧=\(videoDecoder.hardwareFrameCount) 软解帧=\(videoDecoder.softwareFrameCount) "
            + "丢帧=\(videoDecoder.droppedFrameCount) "
            + "解码错误=\(videoDecoder.decodeErrorCount) 音频样本=\(audioSamplesEnqueued)"
        LibavTrace.logger.notice("\(summary, privacy: .public)")
        emitEndedOnce()
    }

    /// 收一帧视频：先发上一帧（现在知道它的时长了），把这一帧留成 pending。
    private func consume(_ frame: LibavVideoDecoder.Frame) {
        noteDecodePath(isHardware: frame.isHardware)
        if let pending = pendingFrame {
            let delta = frame.seconds - pending.seconds
            let duration = delta > 0.001 ? delta : lastFrameDelta
            lastFrameDelta = duration
            enqueue(pending, duration: duration)
        }
        pendingFrame = frame
    }

    /// 最后一帧：拿不到「下一帧」的差值了，用最近一次间隔兜底。
    private func finishPendingFrame() {
        guard let pending = pendingFrame else { return }
        pendingFrame = nil
        enqueue(pending, duration: lastFrameDelta)
    }

    private func enqueue(_ frame: LibavVideoDecoder.Frame, duration: Double) {
        let accepted = videoRenderer.enqueue(
            pixelBuffer: frame.pixelBuffer,
            presentationSeconds: frame.seconds,
            durationSeconds: duration
        )
        guard accepted else { return }
        videoFramesAccepted += 1
        // 第一帧真的排上了，才算「开始播」—— 在此之前界面那边还是 loading。
        if !startedPlaying {
            startedPlaying = true
            lock.lock()
            playing = true
            let rate = rate
            lock.unlock()
            videoRenderer.play(rate: rate)
            emit(.state(.playing))
        }
    }

    /// 记下这一帧走的哪条路（播放信息的「解码」行说实话用）。
    ///
    /// 为什么得由第一帧来定：硬解到底生不生效只有帧自己知道 —— 解码层收到非 VT 帧时会记旗标，
    /// 会话这边另查 `hardwareFallbackDetected` 并**停下报错**（不自动降级）。
    private func noteDecodePath(isHardware: Bool) {
        lock.lock()
        let previous = actualDecodeIsHardware
        if previous == nil || (previous == true && !isHardware) {
            actualDecodeIsHardware = isHardware
        }
        lock.unlock()
    }

    /// 硬解模式下 libav 掉回软解：**不自动降级**（用户拍板：硬解 / 软解由人手动选）——
    /// 停下并让用户去把设置改成「软件解码」。
    private func failHardwareFallback() {
        guard !reportedHardwareFallback else { return }
        reportedHardwareFallback = true
        finishedEof = true
        let reason = "硬解没生效（这台机器没有可用的 VideoToolbox 硬解）："
            + "请到「设置 → 播放 → 解码方式」改成「软件解码」"
        emit(.state(.failed(reason)))
    }

    /// 「有声音没画面」的取证（M04P13）：解码跑起来 3 秒还是一帧没进显示层，就把两侧计数打出来。
    ///
    /// 放在这条循环里是因为：这些计数只有解码线程在碰，读它们不用锁；
    /// 打过一次就不再查（连 `Date()` 也不再多花）。
    private func reportVideoSilenceIfNeeded() {
        guard !loggedVideoSilence, videoFramesAccepted == 0, audioSamplesEnqueued > 0 else { return }
        guard Date().timeIntervalSince(loopStartedAt) >= 3 else { return }
        loggedVideoSilence = true
        let silence = "解码 3 秒后仍没有一帧进显示层：视频包=\(routedVideoPackets) "
            + "硬解帧=\(videoDecoder.hardwareFrameCount) 软解帧=\(videoDecoder.softwareFrameCount) "
            + "丢帧=\(videoDecoder.droppedFrameCount) "
            + "解码错误=\(videoDecoder.decodeErrorCount) "
            + "最后一次=\(videoDecoder.lastDecodeErrorText ?? "无") 音频样本=\(audioSamplesEnqueued)"
        LibavTrace.logger.error("\(silence, privacy: .public)")
    }

    private func emitTimeIfNeeded() {
        let current = videoRenderer.currentSeconds
        guard abs(current - lastEmittedSeconds) >= 0.25 else { return }
        lastEmittedSeconds = current
        emit(.time(current: current, duration: durationSeconds))
    }

    private func emitEndedOnce() {
        lock.lock()
        let already = endedEmitted
        endedEmitted = true
        lock.unlock()
        guard !already else { return }
        emit(.state(.ended))
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func isDecodeFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return decodeFinished
    }

    private func markDecodeFinished() {
        lock.lock()
        decodeFinished = true
        lock.unlock()
    }

    private func emit(_ event: FFmpegSessionEvent) {
        continuation?.yield(event)
    }
}
