import AVFoundation
import CoreVideo
import Foundation

/// 自研 FFmpeg 内核的**真实会话**（M04P14 起：音视频 + seek + 软解兜底都接上）：
/// 统一 demux（`LibavInput.nextPacket`）→ 视频走解码器进显示层（**按设置的解码方式：硬解 / 软解，不自动降级**）、
/// 音频走 libavcodec + swresample 进音频渲染器；两者挂**同一条** synchronizer。
///
/// 当前已知缺口（**如实说，别让界面以为它全能**；M04P13 已把它接进界面）：
/// - 换音轨 v1 **不做重定位**：从当前读包位置往后接（新轨的头几帧可能比画面晚一点点），
///   不回头把新轨对齐到当前时刻；
/// - 字幕轨还没有（轨道清单里不报，界面就不显示那组选择）；
/// - 网络读阻塞期间 `close()` 不保证立刻收线程 —— 在没有 interrupt callback 之前，
///   宁可让线程自然退出，也不释放它可能正在读的上下文；
/// - `stats()` 里画面那几行是**打开时读到的事实**（分辨率 / 编码 / 容器），不是 mpv 那种逐帧快照；
///   「解码 / 输出」两行例外 —— 它们是第一帧实测出来的。
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

    /// 第一帧进过显示层没有、读到尾没有：解码线程写，但**看门狗线程会读**（M04P17）—— 读写都走 `lock`。
    private var startedPlaying = false
    private var finishedEof = false

    // 以下只在解码线程里碰：不需要锁
    private var pendingFrame: LibavVideoDecoder.Frame?
    private var lastFrameDelta = 1.0 / 30
    private var lastEmittedSeconds = -10.0

    /// 排障计数（M04P13 起，**只在解码线程里读写**）：两侧各喂进去多少、开跑多久。
    /// 「有声音没画面」的判断就靠它们（见 `reportVideoSilenceIfNeeded()`）。
    private var routedVideoPackets = 0
    private var videoFramesAccepted = 0
    private var audioSamplesEnqueued = 0
    private var loopStartedAt = Date()
    private var loggedVideoSilence = false
    /// 当前音轨的流下标（`nil` = 没有音轨 / 被关掉）：解码线程写、`stats()` 读 —— 用 `lock` 串。
    private var audioStreamIndex: Int?
    /// 待办的换轨请求（控制线程放、解码线程取；`nil` = 没有待办）。与 seek 同一套：一段读包的人只能有一个。
    private var pendingAudioTrack: PendingAudioTrack?

    /// 饥饿看门狗（M04P17）：解码线程喂帧、看门狗线程心跳；状态机与判定是纯逻辑（``FeedStarvationWatchdog``）。
    private var starvationWatchdog = FeedStarvationWatchdog()
    /// 最后一帧的 pts（秒）：解码线程写、看门狗线程读 —— 用 `lock` 串。
    private var lastFedSeconds: Double = 0

    /// 实际跑起来的解码路径（第一帧定）：解码线程写、控制路径（`stats()`）读 —— 用 `lock` 串。
    private var actualDecodeIsHardware: Bool?
    /// 真正交给显示层的像素格式（第一帧的 `CVPixelBuffer` 实测）：播放信息「输出」那行用。
    private var actualOutputPixelFormat: String?
    /// 解码侧丢帧快照（解码线程写、控制路径读，都走 `lock`）。
    private var decoderDroppedSnapshot = 0
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
        let firstAudio = input.firstStreamIndex(of: .audio)
        if let firstAudio {
            let decoder = LibavAudioDecoder()
            if let failure = decoder.open(input: input, streamIndex: firstAudio) {
                decoder.close()
                videoDecoder.close()
                input.close()
                return failure
            }
            audioDecoder = decoder
            audioStreamIndex = firstAudio
        }
        info = input.mediaInfo()
        durationSeconds = info?.durationSeconds ?? 0
        // 轨道清单：**开片报一次**（换轨不重报 —— 重报会让界面把用户刚选的那条复位成「自动」）。
        // 字幕轨我们还没有：报空数组 = 界面不显示字幕选择，如实（M04P16）。
        let videoTracks = info?.streams.filter { $0.kind == .video }.map(\.index) ?? []
        let audioTracks = info?.streams.filter { $0.kind == .audio }.map(\.index) ?? []
        emit(.tracks(video: videoTracks, audio: audioTracks, subtitle: []))
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
        let watchdog = Thread { [weak self] in self?.watchdogLoop() }
        watchdog.name = "yplayer-ffmpeg-watchdog"
        watchdog.qualityOfService = .utility
        watchdog.start()
    }

    /// 解码主循环：背压等 → 取包 → 按流分发给两个解码器 → 喂对应的渲染器。
    private func decodeLoop() {
        defer { markDecodeFinished() }
        while isRunning() {
            if let target = takePendingSeek() {
                performSeek(to: target)
                continue
            }
            if let request = takePendingAudioTrack() {
                performAudioSwitch(to: request)
                continue
            }
            if isFinishedEof() {
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
            noteDroppedFrames()
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
        lock.lock()
        // 第一帧回来后重新报 .playing：从 .ended 跳回来也要能复播。
        finishedEof = false
        startedPlaying = false
        endedEmitted = false
        let playing = playing
        let rate = rate
        lock.unlock()
        lastEmittedSeconds = seconds
        videoRenderer.reset(to: seconds, playing: playing, rate: rate)
        audioRenderer.flush()
    }

    /// 读到尾了没有（解码线程写、看门狗线程读 —— 走锁）。
    private func isFinishedEof() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedEof
    }

    private func setFinishedEof(_ value: Bool) {
        lock.lock()
        finishedEof = value
        lock.unlock()
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
        setFinishedEof(true)
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
        noteDecodePath(frame)
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

// MARK: - 换音轨（M04P16）

/// 换音轨：控制线程只记账（`selectTrack`），真正的切换在解码线程里做（`performAudioSwitch`）。
///
/// 为什么拆成扩展：类型体行数（`type_body_length`）会把 CI 的 lint 顶红，
/// 而**扩展不计入类型体** —— 主声明留状态与主循环，各组职责放这儿（同文件，`private` 照旧可见）。
extension LibavFFmpegSession {
    /// 换轨请求的三种形态（对齐 `TrackSelection`）。
    private enum PendingAudioTrack {
        /// 回到容器里的第一条音轨。
        case automatic
        /// 切到指定流下标。
        case stream(Int)
        /// 关掉音轨。
        case disabled
    }

    /// 换音轨（M04P16）：这里只**记账**，真正的切换在解码线程里做（`performAudioSwitch`）。
    ///
    /// - `.auto`：回到容器里的第一条音轨；
    /// - `.disabled`：把音轨关掉（拆解码器，不是静音假装）；
    /// - `.index`：切到那条流 —— 不是音频流 / 开不了，会保留旧轨继续响（原因进日志）。
    ///
    /// 字幕轨还没做（轨道清单里也没报出去）：这里如实忽略，不假装生效。
    func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        guard kind == .audio else { return }
        lock.lock()
        switch selection {
        case .auto: pendingAudioTrack = .automatic
        case let .index(index): pendingAudioTrack = .stream(index)
        case .disabled: pendingAudioTrack = .disabled
        }
        lock.unlock()
    }

    /// 取走待办换轨（解码线程消费；控制线程只放不快取）。
    private func takePendingAudioTrack() -> PendingAudioTrack? {
        lock.lock()
        defer { lock.unlock() }
        let request = pendingAudioTrack
        pendingAudioTrack = nil
        return request
    }

    /// 当前音轨的流下标（`nil` = 没有音轨 / 被关掉）；解码线程与 `stats()` 都读，走锁。
    private func currentAudioIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return audioStreamIndex
    }

    /// 换音轨（**只在解码线程里跑**）：新解码器先建好，成了才换、才 flush ——
    /// 换不过去就保留旧轨继续响（不静音、不假装），原因进日志。
    ///
    /// v1 口径：**不做重定位** —— 新轨从当前读包位置往后接（见类文档的缺口清单）。
    private func performAudioSwitch(to request: PendingAudioTrack) {
        let target: Int?
        switch request {
        case .automatic:
            target = input.firstStreamIndex(of: .audio)
        case let .stream(index):
            target = index
        case .disabled:
            target = nil
        }
        guard let target else {
            // 关掉音轨（或本来就没有音轨）：拆解码器 + 清掉已排队的样本。
            audioDecoder?.close()
            audioDecoder = nil
            audioRenderer.flush()
            lock.lock()
            audioStreamIndex = nil
            lock.unlock()
            return
        }
        guard target != currentAudioIndex() else { return }
        let candidate = LibavAudioDecoder()
        if let failure = candidate.open(input: input, streamIndex: target) {
            candidate.close()
            let note = "换音轨失败（流 \(target)）：\(failure) —— 继续放旧轨"
            LibavTrace.logger.error("\(note, privacy: .public)")
            return
        }
        audioDecoder?.close()
        audioDecoder = candidate
        // 清掉旧轨已经排队的样本：不清的话换完还会先响一段旧的。
        audioRenderer.flush()
        lock.lock()
        audioStreamIndex = target
        lock.unlock()
    }
}

// MARK: - 排障与播放信息

/// 排障与播放信息：播放信息那几行、硬解回退的失败出口、以及「有声音没画面」的取证日志。
///
/// 为什么拆成扩展：类型体行数（`type_body_length`）会把 CI 的 lint 顶红，
/// 而**扩展不计入类型体** —— 主声明留状态与主循环，各组职责放这儿（同文件，`private` 照旧可见）。
extension LibavFFmpegSession {
    func stats() async -> PlaybackStats {
        guard let info else {
            return PlaybackStats()
        }
        var raw: [String: String] = [:]
        if let video = info.streams.first(where: { $0.kind == .video }) {
            raw["video-params/w"] = String(video.width)
            raw["video-params/h"] = String(video.height)
            raw["video-format"] = video.codecName
            if video.fps > 0 {
                raw["container-fps"] = String(video.fps)
            }
            // 源色彩：读不到就是空 —— 播放信息那边「空就不显示」，不猜。
            if !video.primaries.isEmpty {
                raw["video-params/primaries"] = video.primaries
            }
            if !video.gamma.isEmpty {
                raw["video-params/gamma"] = video.gamma
            }
        }
        // 音轨可能已经换过（M04P16）：按**当前**那条流的编码名报，不照抄打开时的第一条。
        if let audioIndex = currentAudioIndex(),
           let audio = info.streams.first(where: { $0.index == audioIndex })
        {
            raw["audio-codec"] = audio.codecName
        }
        if !info.containerName.isEmpty {
            raw["file-format"] = info.containerName
        }
        // 下面三行都是**第一帧实测**出来的（锁里取快照）：一帧还没到就先不写，宁可空着也不猜。
        // - 「解码」：实际拿到的是哪种帧（选硬解而硬解不可用时链路会停下报错）；
        // - 「输出」：真正交给显示层的像素格式（硬解是 VT 的 buffer、软解是我们转的 420v）；
        // - 「丢帧」：解码侧丢了多少（转换不出来的帧）—— 显示侧我们没有读法，不替它写 0。
        lock.lock()
        let isHardware = actualDecodeIsHardware
        let outputPixelFormat = actualOutputPixelFormat
        let decoderDropped = decoderDroppedSnapshot
        lock.unlock()
        if let isHardware {
            raw["hwdec-current"] = isHardware ? "videotoolbox" : "no"
        }
        if let outputPixelFormat {
            raw["video-out-params/pixelformat"] = outputPixelFormat
        }
        if decoderDropped > 0 {
            raw["decoder-frame-drop-count"] = String(decoderDropped)
        }
        return PlaybackStats(rawValues: raw)
    }

    /// 记下这一帧走的哪条路、交给显示层的像素格式（播放信息「解码 / 输出」两行说实话用）。
    ///
    /// 为什么得由第一帧来定：硬解到底生不生效只有帧自己知道 —— 解码层收到非 VT 帧时会记旗标，
    /// 会话这边另查 `hardwareFallbackDetected` 并**停下报错**（不自动降级）。
    private func noteDecodePath(_ frame: LibavVideoDecoder.Frame) {
        let format = LibavVideoDecoder.fourCC(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))
        lock.lock()
        let previous = actualDecodeIsHardware
        if previous == nil || (previous == true && !frame.isHardware) {
            actualDecodeIsHardware = frame.isHardware
        }
        if actualOutputPixelFormat != format {
            actualOutputPixelFormat = format
        }
        lock.unlock()
    }

    /// 解码侧丢帧计数进快照（跟 `stats()` 共用一把锁）：只在变化时写，别让它每包都转一次锁。
    private func noteDroppedFrames() {
        let dropped = videoDecoder.droppedFrameCount
        guard dropped != decoderDroppedSnapshot else { return }
        lock.lock()
        decoderDroppedSnapshot = dropped
        lock.unlock()
    }

    /// 硬解模式下 libav 掉回软解：**不自动降级**（用户拍板：硬解 / 软解由人手动选）——
    /// 停下并让用户去把设置改成「软件解码」。
    private func failHardwareFallback() {
        guard !reportedHardwareFallback else { return }
        reportedHardwareFallback = true
        setFinishedEof(true)
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
}

// MARK: - 时钟纪律（M04P17）

/// 时钟跟着帧走：喂帧时恢复时间轴（`enqueue`），饿了由看门狗线程停表（`watchdogLoop`）。
///
/// 为什么拆成扩展：类型体行数（`type_body_length`）会把 CI 的 lint 顶红，
/// 而**扩展不计入类型体** —— 主声明留状态与主循环，各组职责放这儿（同文件，`private` 照旧可见）。
extension LibavFFmpegSession {
    private func enqueue(_ frame: LibavVideoDecoder.Frame, duration: Double) {
        let accepted = videoRenderer.enqueue(
            pixelBuffer: frame.pixelBuffer,
            presentationSeconds: frame.seconds,
            durationSeconds: duration
        )
        guard accepted else { return }
        videoFramesAccepted += 1
        // 时钟跟着帧走（M04P17）：记下这帧的 pts + 从饥饿里恢复；第一帧真排上了才算「开始播」
        // （在此之前界面那边还是 loading）。这些值跨线程读，一次锁里办完。
        lock.lock()
        lastFedSeconds = frame.seconds
        let wasStarving = starvationWatchdog.noteFeed()
        let resumeRate = rate
        let isPlayingNow = playing
        let isFirstFrame = !startedPlaying
        if isFirstFrame {
            startedPlaying = true
            playing = true
        }
        lock.unlock()
        // 恢复只在「还在播」时做：暂停 / 用户自己停了表的时候，喂帧不许把表接回去。
        if isFirstFrame || (wasStarving && isPlayingNow) {
            videoRenderer.play(rate: resumeRate)
            emit(.state(.playing))
        }
    }

    /// 看门狗线程（M04P17）：每 0.2s 看一眼「时钟是不是跑到数据前面了」。
    ///
    /// 为什么非要**另一条线程**：解码线程可能正卡在一次阻塞读里（网络慢 / 掉线），
    /// 那时它自己没法报「卡住了」，只能从外面看。这条线程只做三件事：
    /// 读锁里的状态、判饥饿、停表 + 报「缓冲中」—— 恢复由解码线程在喂帧时做（``enqueue(_:duration:)``）。
    ///
    /// **时钟跟着帧走**：不停表的话，时钟会一直往前跑，恢复后那批帧全成了「迟到帧」，
    /// 显示层按规矩丢掉它们 —— 用户看到的就不是「停一下」，而是「卡完突然快进一段」。
    private func watchdogLoop() {
        while isRunning() {
            Thread.sleep(forTimeInterval: 0.2)
            guard isRunning() else { return }
            lock.lock()
            let watching = playing && startedPlaying && !finishedEof
            let becameStarving = watching
                ? starvationWatchdog.tick(
                    clockSeconds: videoRenderer.currentSeconds,
                    lastFedSeconds: lastFedSeconds
                )
                : false
            lock.unlock()
            guard becameStarving else { continue }
            videoRenderer.pause()
            emit(.state(.buffering))
        }
    }
}
