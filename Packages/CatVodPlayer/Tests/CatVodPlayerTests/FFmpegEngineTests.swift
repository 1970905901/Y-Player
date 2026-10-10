@testable import CatVodPlayer
import Foundation
import Testing

/// 假 FFmpeg 会话：不碰 C、不碰真机 —— 记下引擎下了什么命令，并按脚本吐事件。
///
/// 存在的理由（与 `FakeMpvSession` 同）：真管线（demux / 解码 / 渲染）只有在 Mac 上才能验，
/// 但引擎的**语义**现在就能用它在 CI 上钉死。
///
/// `@unchecked Sendable` 的成立条件：所有可变状态都在锁内访问。
final class FakeFFmpegSession: FFmpegSession, @unchecked Sendable {
    /// 收到的调用（顺序敏感：能断言「load 先 open、命令按序下发」）。
    enum Call: Equatable {
        case open(url: String, headers: [String: String], decoderMode: DecoderMode)
        case play
        case pause
        case seek(to: Double)
        case rate(Float)
        case volume(Float)
        case select(TrackSelection, TrackKind)
        case stats
        case close
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var statsValue = PlaybackStats()
    private let openFailure: String?
    let events: AsyncStream<FFmpegSessionEvent>
    private let eventContinuation: AsyncStream<FFmpegSessionEvent>.Continuation?

    init(openFailure: String? = nil) {
        self.openFailure = openFailure
        var captured: AsyncStream<FFmpegSessionEvent>.Continuation?
        events = AsyncStream<FFmpegSessionEvent> { captured = $0 }
        eventContinuation = captured
    }

    // MARK: - 断言用

    /// 收到的调用（按顺序）。
    var recorded: [Call] {
        locked { calls }
    }

    /// 被关闭了几次（真会话必须幂等，这里用来验「换片先关旧会话」）。
    var closeCount: Int {
        locked { calls.filter { $0 == .close }.count }
    }

    /// 打开过的地址（按顺序）。
    var openedURLs: [String] {
        locked {
            calls.compactMap { call in
                guard case let .open(url, _, _) = call else { return nil }
                return url
            }
        }
    }

    func setStats(_ stats: PlaybackStats) {
        locked { statsValue = stats }
    }

    /// 塞一件事件（模拟真管线往引擎方向报信号）。
    func push(_ event: FFmpegSessionEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - FFmpegSession

    func open(_ resource: MediaResource, decoderMode: DecoderMode) async -> String? {
        record(.open(url: resource.url, headers: resource.headers, decoderMode: decoderMode))
        return openFailure
    }

    func play() async {
        record(.play)
    }

    func pause() async {
        record(.pause)
    }

    func seek(to seconds: Double) async {
        record(.seek(to: seconds))
    }

    func setRate(_ rate: Float) async {
        record(.rate(rate))
    }

    func setVolume(_ volume: Float) async {
        record(.volume(volume))
    }

    func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        record(.select(selection, kind))
    }

    func stats() async -> PlaybackStats {
        record(.stats)
        return locked { statsValue }
    }

    func close() async {
        record(.close)
    }

    // MARK: - 内部

    private func record(_ call: Call) {
        locked { calls.append(call) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 建一个用假会话的引擎（工厂每次都给同一个假会话，便于断言累积的调用）。
private func makeEngine(
    decoderMode: DecoderMode = .hardware,
    openFailure: String? = nil
) -> (engine: FFmpegEngine, session: FakeFFmpegSession) {
    let session = FakeFFmpegSession(openFailure: openFailure)
    let engine = FFmpegEngine(decoderMode: decoderMode, makeSession: { session })
    return (engine, session)
}

/// 轮询等状态：引擎没有状态观察 API，单测只能这样等。
///
/// 上限 100 次 × 10ms = 1s：事件没来时**失败**而不是挂死（CI 上挂死比失败难查得多）。
private func waitForState(_ engine: FFmpegEngine, _ expected: PlayerState) async -> PlayerState {
    var state = await engine.currentState()
    var remaining = 100
    while state != expected, remaining > 0 {
        try? await Task.sleep(nanoseconds: 10_000_000)
        state = await engine.currentState()
        remaining -= 1
    }
    return state
}

/// 自研 FFmpeg 引擎的**语义**（用假会话在 CI 上跑）。
///
/// 覆盖：加载 / 命令下发 / 事件与状态 / 错误路径 / 生命周期。
/// **不覆盖**：真管线（demux、解码、渲染、音频）—— 那是 M04P6 起的事，且只能在 Mac 上验。
@Suite("FFmpeg 引擎（假会话）")
struct FFmpegEngineTests {
    @Test("load：先 open（带上 decoderMode 与 headers），成功即报 .loading")
    func loadOpensSession() async throws {
        let (engine, session) = makeEngine(decoderMode: .software)
        var iterator = engine.events.makeAsyncIterator()
        let resource = MediaResource(
            url: "https://cdn.example.com/a.m3u8",
            headers: ["User-Agent": "YPlayer", "Referer": "https://example.com"]
        )
        try await engine.load(resource)

        #expect(session.openedURLs == ["https://cdn.example.com/a.m3u8"])
        // 字典比较不看键序：headers 原样到达即可
        let open = try #require(session.recorded.first)
        #expect(open == .open(
            url: "https://cdn.example.com/a.m3u8",
            headers: ["User-Agent": "YPlayer", "Referer": "https://example.com"],
            decoderMode: .software
        ))

        let loading = await iterator.next()
        #expect(loading == .stateChanged(.loading))
        let state = await engine.currentState()
        #expect(state == .loading)
    }

    @Test("命令：play / pause / seek（负数夹 0）/ 倍速 / 音量（夹 0...1）/ 轨道 都下发给会话")
    func commands() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.play()
        await engine.pause()
        await engine.seek(to: 90)
        await engine.seek(to: -5)
        await engine.setRate(1.5)
        await engine.setVolume(0.5)
        await engine.setVolume(1.5)
        await engine.selectTrack(.disabled, for: .subtitle)
        await engine.selectTrack(.index(2), for: .audio)

        // 第一条是 open，剩下的是上面这九条（顺序即调用顺序）
        let issued = Array(session.recorded.dropFirst())
        #expect(issued == [
            .play,
            .pause,
            .seek(to: 90),
            .seek(to: 0),
            .rate(1.5),
            .volume(0.5),
            .volume(1),
            .select(.disabled, .subtitle),
            .select(.index(2), .audio),
        ])
    }

    @Test("seek 的回执立刻发（UI 不等内核往返）")
    func seekEcho() async throws {
        let (engine, _) = makeEngine()
        var iterator = engine.events.makeAsyncIterator()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        _ = await iterator.next()
        await engine.handle(.time(current: 5, duration: 120))
        _ = await iterator.next()

        await engine.seek(to: 90)
        let echoed = await iterator.next()
        #expect(echoed == .timeChanged(current: 90, duration: 120))
    }

    @Test("事件映射：state / time / buffered / tracks")
    func eventMapping() async throws {
        let (engine, _) = makeEngine()
        var iterator = engine.events.makeAsyncIterator()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.handle(.state(.playing))
        await engine.handle(.time(current: 7.5, duration: 120))
        await engine.handle(.buffered(seconds: 30))
        await engine.handle(.tracks(video: [1], audio: [2], subtitle: [3]))

        let loading = await iterator.next()
        #expect(loading == .stateChanged(.loading))
        let playing = await iterator.next()
        #expect(playing == .stateChanged(.playing))
        let time = await iterator.next()
        #expect(time == .timeChanged(current: 7.5, duration: 120))
        let buffered = await iterator.next()
        #expect(buffered == .bufferedChanged(seconds: 30))
        let tracks = await iterator.next()
        #expect(tracks == .tracksChanged(video: [1], audio: [2], subtitle: [3]))
        let state = await engine.currentState()
        #expect(state == .playing)
    }

    @Test("事件循环：往会话里塞事件，引擎自己会消费（真机那圈胶水）")
    func eventLoopConsumesSessionEvents() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        session.push(.state(.playing))
        let state = await waitForState(engine, .playing)
        #expect(state == .playing)
        await engine.teardown()
    }

    @Test("错误路径：URL 非法 / 工厂给 nil / open 失败")
    func errorPaths() async throws {
        let (engine, session) = makeEngine()
        await #expect(throws: PlayerError.invalidURL("not a url")) {
            try await engine.load(MediaResource(url: "not a url"))
        }
        // URL 都没过，不该建会话
        #expect(session.recorded.isEmpty)

        // 没有真会话（工厂给 nil）→ 内核不可用
        let noSession = FFmpegEngine(decoderMode: .hardware, makeSession: { nil })
        await #expect(throws: PlayerError.engineUnavailable(.ffmpeg)) {
            try await noSession.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        }
        let unavailable = await noSession.currentState()
        #expect(unavailable == .failed(PlayerError.engineUnavailable(.ffmpeg).message))

        // open 失败：报出来，且会话必须被关掉（真机上就是漏一个管线实例）
        let (broken, brokenSession) = makeEngine(openFailure: "连不上")
        await #expect(throws: PlayerError.loadFailed("连不上")) {
            try await broken.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        }
        #expect(brokenSession.closeCount == 1)
        let brokenState = await broken.currentState()
        #expect(brokenState == .failed("连不上"))
    }

    @Test("teardown：关闭会话、状态回 idle、还能再 load")
    func teardownAndReuse() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.teardown()
        #expect(session.closeCount == 1)
        let idle = await engine.currentState()
        #expect(idle == .idle)

        try await engine.load(MediaResource(url: "https://cdn.example.com/b.m3u8"))
        let loading = await engine.currentState()
        #expect(loading == .loading)
        // 手动 teardown 之后 session 已置 nil，这次 load 没有旧会话可关
        #expect(session.closeCount == 1)
    }

    @Test("连续 load 会自己关掉上一份会话（没手动 teardown 也不会漏）")
    func loadClosesPreviousSession() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        #expect(session.closeCount == 0)

        try await engine.load(MediaResource(url: "https://cdn.example.com/b.m3u8"))
        #expect(session.closeCount == 1, "第二次 load 必须先关掉第一份会话")

        await engine.teardown()
        #expect(session.closeCount == 2)
    }

    @Test("播放信息：转发会话快照；没有会话给空值")
    func playbackStatsForwarding() async throws {
        let (engine, session) = makeEngine()
        let empty = await engine.playbackStats()
        #expect(empty.isEmpty)

        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        session.setStats(PlaybackStats(rawValues: [
            "video-params/w": "3840",
            "video-params/h": "2160",
        ]))
        let stats = await engine.playbackStats()
        #expect(stats.resolutionText == "3840×2160")
    }
}
