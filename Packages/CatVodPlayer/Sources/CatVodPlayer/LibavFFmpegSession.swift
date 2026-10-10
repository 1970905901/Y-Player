import Foundation

/// 自研 FFmpeg 内核的**真实会话**（M04P9，视频-only 第一版）：
/// 输入（demux）→ VT 硬解 → 显示层，跑在一条专用解码线程上。
///
/// 这一版的边界（**接线进界面之前必须补齐**，别让界面以为它全能）：
/// - **没有音频**（M04P10）；
/// - **没有 seek / 起点续播**：`startPosition` 被忽略，seek 是空操作（不假装）；
/// - **软解没做**：`decoderMode == .software` 直接拒绝（不假装生效）；
/// - 网络读阻塞期间 `close()` 不保证立刻收线程 —— 在没有 interrupt callback 之前，
///   宁可让线程自然退出，也不释放它可能正在读的上下文；
/// - `stats()` 给的是**打开时读到的事实**（分辨率 / 编码 / 容器 / 硬解），
///   不是 mpv 那种逐帧快照。
///
/// 分层：C 调用全在 `LibavInput` / `LibavVideoDecoder` / `LibavVideoRenderer` 里，
/// 本类只管线程、状态与背压。一个会话只服务一次打开（引擎换片会新建会话）。
final class LibavFFmpegSession: FFmpegSession, @unchecked Sendable {
    /// 一次从解码器拿几帧（太小费调度，太大压不住背压）。
    private static let decodeChunk = 4

    private let input = LibavInput()
    private let decoder = LibavVideoDecoder()
    private let renderer: any FFmpegVideoRendering
    let events: AsyncStream<FFmpegSessionEvent>
    private let continuation: AsyncStream<FFmpegSessionEvent>.Continuation?

    private let lock = NSLock()
    private var running = false
    private var decodeFinished = false
    private var playing = false
    private var rate: Float = 1
    private var endedEmitted = false
    private var durationSeconds: Double = 0
    private var info: LibavInput.MediaInfo?

    // 以下只在解码线程里碰：不需要锁
    private var startedPlaying = false
    private var pendingFrame: LibavVideoDecoder.Frame?
    private var lastFrameDelta = 1.0 / 30
    private var lastEmittedSeconds = -10.0
    private var finishedEof = false

    /// 生产入口：给画面层。
    init(surface: FFmpegVideoSurface) {
        self.init(renderer: LibavVideoRenderer(surface: surface))
    }

    /// 单测入口：给假渲染器（真输入 / 真解码仍会跑 —— 集成测试的用法）。
    init(renderer: any FFmpegVideoRendering) {
        self.renderer = renderer
        var captured: AsyncStream<FFmpegSessionEvent>.Continuation?
        events = AsyncStream<FFmpegSessionEvent> { captured = $0 }
        continuation = captured
    }

    // MARK: - FFmpegSession

    func open(_ resource: MediaResource, decoderMode: DecoderMode) async -> String? {
        guard decoderMode == .hardware else {
            return "自研内核第一版只有硬解（软解在后面），先把设置换成硬件解码"
        }
        if let failure = input.open(url: resource.url, headers: resource.headers) {
            return failure
        }
        if let failure = decoder.open(input: input) {
            return failure
        }
        info = input.mediaInfo()
        durationSeconds = info?.durationSeconds ?? 0
        startDecodeLoop()
        return nil
    }

    func play() async {
        lock.lock()
        playing = true
        let rate = rate
        lock.unlock()
        renderer.play(rate: rate)
        emit(.state(.playing))
    }

    func pause() async {
        lock.lock()
        playing = false
        lock.unlock()
        renderer.pause()
        emit(.state(.paused))
    }

    func seek(to seconds: Double) async {
        // 还没做（下一片）：**不假装** —— 什么都不动，拖进度条要等真实实现。
        _ = seconds
    }

    func setRate(_ rate: Float) async {
        lock.lock()
        self.rate = rate
        let playing = playing
        lock.unlock()
        if playing {
            renderer.play(rate: rate)
        }
    }

    func setVolume(_ volume: Float) async {
        // 音频还没做（M04P10）。
        _ = volume
    }

    func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        // 轨道选择还没做：现在只有一条视频流。
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
        if !info.containerName.isEmpty {
            raw["file-format"] = info.containerName
        }
        // 打开时 VT 设备已经建成功（建不出会直接报错），所以这里不是猜。
        raw["hwdec-current"] = "videotoolbox"
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
            decoder.close()
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

    /// 解码主循环：背压等 → 取帧 → 攒一帧的时长再喂（时长要等下一帧 pts 才知道）。
    private func decodeLoop() {
        defer { markDecodeFinished() }
        while isRunning() {
            if !renderer.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            if finishedEof {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let frames = decoder.decodeFrames(Self.decodeChunk)
            for frame in frames {
                consume(frame)
            }
            if decoder.reachedEnd {
                finishedEof = true
                for frame in decoder.drain() {
                    consume(frame)
                }
                finishPendingFrame()
                emitEndedOnce()
                continue
            }
            if frames.isEmpty {
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                emitTimeIfNeeded()
            }
        }
    }

    /// 收一帧：先发上一帧（现在知道它的时长了），把这一帧留成 pending。
    private func consume(_ frame: LibavVideoDecoder.Frame) {
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
        let accepted = renderer.enqueue(
            pixelBuffer: frame.pixelBuffer,
            presentationSeconds: frame.seconds,
            durationSeconds: duration
        )
        guard accepted else { return }
        // 第一帧真的排上了，才算「开始播」—— 在此之前界面那边还是 loading。
        if !startedPlaying {
            startedPlaying = true
            lock.lock()
            playing = true
            let rate = rate
            lock.unlock()
            renderer.play(rate: rate)
            emit(.state(.playing))
        }
    }

    private func emitTimeIfNeeded() {
        let current = renderer.currentSeconds
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
