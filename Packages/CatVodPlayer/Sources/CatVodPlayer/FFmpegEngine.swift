import Foundation

/// 自研 FFmpeg 内核（M4）—— 引擎侧：会话生命周期、命令下发、事件到播放语义的翻译。
///
/// 分层（同 `MpvEngine`，M03P3 的结论直接复用）：
/// - **本文件**：`PlayerEngine` 的语义与状态机 —— 用假会话在 CI 上单测（`FFmpegEngineTests`）；
/// - ``FFmpegSession``（seam）：与真管线的边界，C 调用不越界到这里；
/// - 真会话（M04P6 起）：demux / 解码 / 渲染 / 音频，全部收在一个文件里。
///
/// **可用性口径**：引擎骨架 ≠ 能用。``FFmpegAvailability/isEngineImplemented`` 仍是 false，
/// `PlayerCoordinator` 也不会创建本引擎 —— 等真会话落成、真的出得了画面再翻
/// （与 MPV 的 `isVideoOutputReady` 同一条纪律：没有画面 = 不能宣称可用）。
///
/// **状态口径**：状态以会话事件为准（会话知道自己在缓冲还是真的在播），
/// 只有 `.loading` 由引擎在 `open` 成功后发；`seek` / `setRate` 的回执由引擎立刻补发，
/// 让 UI 不等内核往返（对齐 MPV 内核的手感）。
///
/// **并发**：按 `PlayerEngine` 约定用 `actor`；会话的事件流在自己的任务里消费，`teardown()` 取消它。
public actor FFmpegEngine: PlayerEngine, PlaybackStatsProviding {
    nonisolated public let kind: PlayerEngineKind = .ffmpeg
    nonisolated public let events: AsyncStream<PlayerEvent>
    /// 用户选的解码方式（透传给会话：硬解走 VideoToolbox，软解走 libav）。
    nonisolated let decoderMode: DecoderMode

    /// 会话工厂（单测注假的；生产走 ``FFmpegSessionFactory`` —— 现在给 nil）。
    private let makeSession: @Sendable () -> (any FFmpegSession)?
    private var session: (any FFmpegSession)?
    private var eventLoop: Task<Void, Never>?
    private var continuation: AsyncStream<PlayerEvent>.Continuation?
    private var state: PlayerState = .idle
    private var duration: Double = 0

    public init(decoderMode: DecoderMode = .hardware) {
        self.init(decoderMode: decoderMode, makeSession: { FFmpegSessionFactory.make() })
    }

    /// 单测入口：注入会话工厂，不碰真管线。
    init(decoderMode: DecoderMode, makeSession: @escaping @Sendable () -> (any FFmpegSession)?) {
        self.decoderMode = decoderMode
        self.makeSession = makeSession
        var captured: AsyncStream<PlayerEvent>.Continuation?
        events = AsyncStream<PlayerEvent> { captured = $0 }
        continuation = captured
    }

    public func currentState() async -> PlayerState {
        state
    }

    /// 结束事件流（持有者在销毁内核时调用；`teardown()` 不结束流，便于复用引擎加载下一个视频）。
    public func finishEvents() {
        continuation?.finish()
        continuation = nil
    }

    // MARK: - 命令

    public func load(_ resource: MediaResource) async throws {
        guard let url = URL(string: resource.url), url.scheme != nil else {
            throw PlayerError.invalidURL(resource.url)
        }
        await teardown()
        guard let session = makeSession() else {
            update(.failed(PlayerError.engineUnavailable(.ffmpeg).message))
            throw PlayerError.engineUnavailable(.ffmpeg)
        }
        self.session = session
        if let failure = await session.open(resource, decoderMode: decoderMode) {
            await session.close()
            self.session = nil
            update(.failed(failure))
            throw PlayerError.loadFailed(failure)
        }
        // `open` 已受理：从会话来的第一个状态（播放 / 缓冲 / 失败）之前，先让 UI 进「加载中」。
        update(.loading)
        startEventLoop(session)
    }

    public func play() async {
        guard let session else { return }
        await session.play()
    }

    public func pause() async {
        guard let session else { return }
        await session.pause()
    }

    public func seek(to seconds: Double) async {
        guard let session else { return }
        let target = max(seconds, 0)
        await session.seek(to: target)
        emit(.timeChanged(current: target, duration: duration))
    }

    public func setRate(_ rate: Float) async {
        guard let session else { return }
        await session.setRate(rate)
        emit(.speedChanged(rate))
    }

    /// 音量：统一按 0...1 传入（会话内部再翻成自己的刻度）。
    public func setVolume(_ volume: Float) async {
        guard let session else { return }
        await session.setVolume(min(max(volume, 0), 1))
    }

    public func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        guard let session else { return }
        await session.selectTrack(selection, for: kind)
    }

    public func teardown() async {
        eventLoop?.cancel()
        eventLoop = nil
        if let session {
            await session.close()
        }
        session = nil
        state = .idle
        duration = 0
    }

    // MARK: - 播放信息

    /// 读一次播放信息（M04 口径：内核报什么读什么；拼装规则在 ``PlaybackStats``）。
    public func playbackStats() async -> PlaybackStats {
        guard let session else {
            return PlaybackStats()
        }
        return await session.stats()
    }

    // MARK: - 内部

    /// 起事件循环：消费会话的事件流，直到流结束 / 任务被取消。
    ///
    /// - 用 `Task.detached`：纯循环，**不继承** actor 隔离；
    /// - `[weak self]` + 每轮 `guard`：引擎被释放后循环自己退出，不留空转任务；
    /// - `teardown()` / 换片会 `cancel()` 它，所以正常情况下不用等流把事件吐完。
    private func startEventLoop(_ session: any FFmpegSession) {
        eventLoop?.cancel()
        eventLoop = Task.detached { [weak self] in
            for await event in session.events {
                guard let engine = self, !Task.isCancelled else { return }
                await engine.handle(event)
            }
        }
    }

    /// 处理一件会话事件（**内部可见**：单测直接喂事件，与真机的事件循环共用同一套语义）。
    func handle(_ event: FFmpegSessionEvent) {
        switch event {
        case let .state(newState):
            update(newState)
        case let .time(current, duration):
            self.duration = duration
            emit(.timeChanged(current: current, duration: duration))
        case let .buffered(seconds):
            emit(.bufferedChanged(seconds: seconds))
        case let .tracks(video, audio, subtitle):
            emit(.tracksChanged(video: video, audio: audio, subtitle: subtitle))
        }
    }

    private func update(_ newState: PlayerState) {
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PlayerEvent) {
        continuation?.yield(event)
    }
}
