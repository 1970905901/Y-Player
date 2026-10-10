@testable import CatVodPlayer
import Foundation
import Testing

/// 假 libmpv 会话：不碰 C、不碰真机 —— 记下引擎下了什么命令，并按脚本吐事件。
///
/// 存在的理由（M03P1 第 3 步的渲染路径定不下来）：引擎的**语义**现在就能验，
/// 真机只需要再补「画面怎么出来」那一段。
///
/// `@unchecked Sendable` 的成立条件与 `StorageFailureRecorder` 相同：所有可变状态都在锁内访问。
final class FakeMpvSession: MpvSession, @unchecked Sendable {
    /// 收到的调用（顺序敏感：能断言「先设选项、再 initialize、最后 loadfile」）。
    enum Call: Equatable {
        case option(name: String, value: String)
        case initialize
        case observe(property: String, id: UInt64, format: String)
        case command([String])
        case propertyString(name: String)
        case destroy
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var pendingEvents: [MpvSessionEvent] = []
    private let initializeFailure: String?
    private let commandFailure: String?
    /// 脚本化的属性字符串（`track-list` 之类的结构化属性用它喂）。
    private let propertyStrings: [String: String]

    init(
        initializeFailure: String? = nil,
        commandFailure: String? = nil,
        propertyStrings: [String: String] = [:]
    ) {
        self.initializeFailure = initializeFailure
        self.commandFailure = commandFailure
        self.propertyStrings = propertyStrings
    }

    // MARK: - 断言用

    var recorded: [Call] {
        locked { calls }
    }

    /// 收到的选项（后设的覆盖先设的，同 libmpv 语义）。
    var options: [String: String] {
        locked {
            calls.reduce(into: [String: String]()) { result, call in
                guard case let .option(name, value) = call else { return }
                result[name] = value
            }
        }
    }

    /// 收到的命令（按顺序）。
    var commands: [[String]] {
        locked {
            calls.compactMap { call in
                guard case let .command(args) = call else { return nil }
                return args
            }
        }
    }

    /// 被销毁了几次（真会话必须幂等，这里用来验「每个 load 都先销毁旧会话」）。
    var destroyCount: Int {
        locked { calls.filter { $0 == .destroy }.count }
    }

    /// 被 observe 的属性名（按顺序）。
    var observedNames: [String] {
        locked {
            calls.compactMap { call in
                guard case let .observe(property, _, _) = call else { return nil }
                return property
            }
        }
    }

    /// 塞一件事件（模拟 libmpv 往队列里放东西）。
    func push(_ event: MpvSessionEvent) {
        locked { pendingEvents.append(event) }
    }

    // MARK: - MpvSession

    func setOption(name: String, value: String) {
        record(.option(name: name, value: value))
    }

    func initialize() -> String? {
        record(.initialize)
        return initializeFailure
    }

    func observe(property: String, id: UInt64, format: String) {
        record(.observe(property: property, id: id, format: format))
    }

    func command(_ args: [String]) -> String? {
        record(.command(args))
        return commandFailure
    }

    func propertyString(_ name: String) -> String? {
        record(.propertyString(name: name))
        return propertyStrings[name]
    }

    /// 事件立即返回（不睡）：单测不等真时间，队列空就给 `.none` —— 与真实现超时后返回 `.none` 同形。
    func waitEvent(timeout: Double) -> MpvSessionEvent {
        _ = timeout
        return locked { pendingEvents.isEmpty ? .none : pendingEvents.removeFirst() }
    }

    func destroy() {
        record(.destroy)
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
    initializeFailure: String? = nil,
    commandFailure: String? = nil,
    propertyStrings: [String: String] = [:]
) -> (engine: MpvEngine, session: FakeMpvSession) {
    let session = FakeMpvSession(
        initializeFailure: initializeFailure,
        commandFailure: commandFailure,
        propertyStrings: propertyStrings
    )
    let engine = MpvEngine(decoderMode: decoderMode, makeSession: { session })
    return (engine, session)
}

/// 轮询等状态：引擎没有状态观察 API，单测只能这样等。
///
/// 上限 100 次 × 10ms = 1s：事件没来时**失败**而不是挂死（CI 上挂死比失败难查得多）。
private func waitForState(_ engine: MpvEngine, _ expected: PlayerState) async -> PlayerState {
    var state = await engine.currentState()
    var remaining = 100
    while state != expected, remaining > 0 {
        try? await Task.sleep(nanoseconds: 10_000_000)
        state = await engine.currentState()
        remaining -= 1
    }
    return state
}

/// MPV 引擎的**语义**（用假会话在 CI 上跑）。
///
/// 覆盖：资源 → mpv 选项的翻译、命令下发、事件/属性 → 状态与事件、错误路径、生命周期。
/// **不覆盖**：画面（渲染路径第 3 步才定），以及真 libmpv 的 C 交互本身。
@Suite("MPV 引擎（假会话）")
struct MpvEngineTests {
    @Test("load：先设选项 → initialize → observe → loadfile（顺序也是 libmpv 的硬要求）")
    func loadSequence() async throws {
        let (engine, session) = makeEngine()
        let resource = MediaResource(
            url: "https://cdn.example.com/a.m3u8",
            headers: ["User-Agent": "YPlayer", "Referer": "https://example.com"],
            startPosition: 42.5,
            subtitleURLs: ["https://cdn.example.com/a.ass"]
        )
        try await engine.load(resource)

        #expect(session.options["hwdec"] == "auto-safe")
        #expect(session.options["start"] == "42.500")
        // header 拼成 `名: 值` 逗号串，且按名排序（输出稳定，便于排查）
        #expect(session.options["http-header-fields"] == "Referer: https://example.com,User-Agent: YPlayer")
        #expect(session.options["sub-files"] == "https://cdn.example.com/a.ass")
        // 渲染路径未定：**不许**预设 `vo`，否则第 3 步的 PoC 会被这里误导
        #expect(session.options["vo"] == nil)

        #expect(session.observedNames == ["time-pos", "duration", "pause"])
        #expect(session.commands.first == ["loadfile", "https://cdn.example.com/a.m3u8", "replace"])

        // initialize 之前只能有选项：初始化后再设选项在 libmpv 里基本无效
        let indexOfInitialize = try #require(session.recorded.firstIndex(of: .initialize))
        #expect(indexOfInitialize > 0)
        let before = Array(session.recorded.prefix(indexOfInitialize))
        #expect(before.allSatisfy {
            if case .option = $0 { return true }
            return false
        })

        let state = await engine.currentState()
        #expect(state == .loading)
    }

    @Test("软解与起播位置：hwdec=no / 不给 start 时不设这一项")
    func softwareDecoderAndZeroStart() async throws {
        let (engine, session) = makeEngine(decoderMode: .software)
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        #expect(session.options["hwdec"] == "no")
        #expect(session.options["start"] == nil)
        #expect(session.options["http-header-fields"] == nil)
        #expect(session.options["sub-files"] == nil)
    }

    @Test("事件序列：loading → playing → timeChanged（顺序确定，不靠 sleep）")
    func eventSequence() async throws {
        let (engine, _) = makeEngine()
        var iterator = engine.events.makeAsyncIterator()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.handle(.fileLoaded)
        await engine.handle(.property(id: MpvEventMapping.durationID, value: .double(120)))
        await engine.handle(.property(id: MpvEventMapping.timePositionID, value: .double(7.5)))

        let loading = await iterator.next()
        #expect(loading == .stateChanged(.loading))
        let playing = await iterator.next()
        #expect(playing == .stateChanged(.playing))
        // 时长先到：进度条要立刻能画（此时位置还是 0）
        let duration = await iterator.next()
        #expect(duration == .timeChanged(current: 0, duration: 120))
        let time = await iterator.next()
        #expect(time == .timeChanged(current: 7.5, duration: 120))
    }

    @Test("loaded 事件：eof 算结束，error 算失败（stop/quit 是我们自己的动作）")
    func endFileSemantics() async throws {
        let (engine, _) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.handle(.endFile(reason: "eof"))
        let ended = await engine.currentState()
        #expect(ended == .ended)

        await engine.teardown()
        try await engine.load(MediaResource(url: "https://cdn.example.com/b.m3u8"))
        await engine.handle(.endFile(reason: "error"))
        let failed = await engine.currentState()
        #expect(failed == .failed("播放失败（mpv 报告 error）"))
    }

    @Test("加载途中的 pause 变化被忽略（避免「还没加载完就显示播放中」）")
    func pauseDuringLoading() async throws {
        let (engine, _) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.handle(.property(id: MpvEventMapping.pausedID, value: .flag(false)))
        let stillLoading = await engine.currentState()
        #expect(stillLoading == .loading)

        await engine.handle(.fileLoaded)
        await engine.handle(.property(id: MpvEventMapping.pausedID, value: .flag(true)))
        let paused = await engine.currentState()
        #expect(paused == .paused)
        await engine.handle(.property(id: MpvEventMapping.pausedID, value: .flag(false)))
        let resumed = await engine.currentState()
        #expect(resumed == .playing)
    }

    @Test("命令：play / pause / seek / 倍速 / 音量 / 增益（乘进 volume）/ 步进 / 轨道选择 都下发给会话")
    func commands() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.play()
        await engine.pause()
        await engine.seek(to: 90)
        await engine.setRate(1.5)
        await engine.setVolume(0.5)
        await engine.setAudioGain(1.5)
        await engine.stepFrame()
        await engine.selectTrack(.disabled, for: .subtitle)
        await engine.selectTrack(.index(2), for: .audio)
        await engine.selectTrack(.auto, for: .video)

        // 第一条是 loadfile，剩下的是上面这些（顺序即调用顺序）
        // 增益走的是「volume-max 放到 200 + 音量乘起来写 75」—— mpv 只有一只 volume 旋钮。
        let issued = Array(session.commands.dropFirst())
        #expect(issued == [
            ["set", "pause", "no"],
            ["set", "pause", "yes"],
            ["seek", "90.000", "absolute"],
            ["set", "speed", "1.500"],
            ["set", "volume", "50.000"],
            ["set", "volume-max", "200.000"],
            ["set", "volume", "75.000"],
            ["frame-step"],
            ["set", "sid", "no"],
            ["set", "aid", "2"],
            ["set", "vid", "auto"],
        ])
        // 跳转后状态与进度要跟上（UI 立刻画，不等内核回属性）；步进会报「暂停」
        let state = await engine.currentState()
        #expect(state == .paused)
    }

    @Test("teardown：销毁会话、状态回 idle、还能再 load（换片复用同一个引擎）")
    func teardownAndReuse() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        await engine.teardown()
        #expect(session.destroyCount == 1)
        let idle = await engine.currentState()
        #expect(idle == .idle)

        try await engine.load(MediaResource(url: "https://cdn.example.com/b.m3u8"))
        let loading = await engine.currentState()
        #expect(loading == .loading)
        // 已经手动销毁过、会话已置 nil，所以这次 load 没有旧会话可销毁
        #expect(session.destroyCount == 1)
    }

    @Test("连续 load 会自己销毁上一份会话（没手动 teardown 也不会漏）")
    func loadDestroysPreviousSession() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        #expect(session.destroyCount == 0)

        try await engine.load(MediaResource(url: "https://cdn.example.com/b.m3u8"))
        #expect(session.destroyCount == 1, "第二次 load 必须先销毁第一份会话（真机上就是漏一个 libmpv 实例）")

        await engine.teardown()
        #expect(session.destroyCount == 2)
    }

    @Test("错误路径：URL 非法 / 没有会话 / initialize 失败 / loadfile 失败")
    func errorPaths() async throws {
        let (engine, session) = makeEngine()
        await #expect(throws: PlayerError.invalidURL("not a url")) {
            try await engine.load(MediaResource(url: "not a url"))
        }
        // URL 都没过，不该建会话（更不该 initialize）
        #expect(session.recorded.isEmpty)

        // 依赖缺失（工厂给 nil）→ 内核不可用
        let noSession = MpvEngine(decoderMode: .hardware, makeSession: { nil })
        await #expect(throws: PlayerError.engineUnavailable(.mpv)) {
            try await noSession.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        }
        let unavailable = await noSession.currentState()
        #expect(unavailable == .failed(PlayerError.engineUnavailable(.mpv).message))

        // initialize 失败：会话必须被销毁，且不该再下 loadfile
        let (broken, brokenSession) = makeEngine(initializeFailure: "初始化炸了")
        await #expect(throws: PlayerError.loadFailed("初始化炸了")) {
            try await broken.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        }
        #expect(brokenSession.destroyCount == 1)
        #expect(brokenSession.commands.isEmpty)
        let brokenState = await broken.currentState()
        #expect(brokenState == .failed("初始化炸了"))

        // loadfile 失败：报出来，别让界面停在「加载中」
        let (noLoad, _) = makeEngine(commandFailure: "loadfile 炸了")
        await #expect(throws: PlayerError.loadFailed("loadfile 炸了")) {
            try await noLoad.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        }
        let noLoadState = await noLoad.currentState()
        #expect(noLoadState == .failed("loadfile 炸了"))
    }

    @Test("事件循环：往会话里塞事件，引擎自己会消费（真机那圈胶水）")
    func eventLoopConsumesSessionEvents() async throws {
        let (engine, session) = makeEngine()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.m3u8"))
        session.push(.fileLoaded)
        let state = await waitForState(engine, .playing)
        #expect(state == .playing)
        await engine.teardown()
    }

    @Test("file-loaded 后上报轨道列表（音轨 / 字幕轨的下拉框靠它）")
    func trackListReportedAfterLoad() async throws {
        let (engine, _) = makeEngine(propertyStrings: [
            "track-list": #"[{"id":1,"type":"video"},{"id":2,"type":"audio","lang":"zh"},{"id":3,"type":"sub","title":"简体"}]"#,
        ])
        var iterator = engine.events.makeAsyncIterator()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.mp4"))
        await engine.handle(.fileLoaded)

        let loading = await iterator.next()
        #expect(loading == .stateChanged(.loading))
        let playing = await iterator.next()
        #expect(playing == .stateChanged(.playing))
        let tracks = await iterator.next()
        #expect(tracks == .tracksChanged(
            video: [PlayerTrack(id: 1)],
            audio: [PlayerTrack(id: 2, label: "zh")],
            subtitle: [PlayerTrack(id: 3, label: "简体")]
        ))
    }

    @Test("track-list 读不到：什么都不发（别把界面上的选择清空）")
    func trackListAbsentStaysSilent() async throws {
        let (engine, _) = makeEngine()
        var iterator = engine.events.makeAsyncIterator()
        try await engine.load(MediaResource(url: "https://cdn.example.com/a.mp4"))
        await engine.handle(.fileLoaded)
        _ = await iterator.next()
        _ = await iterator.next()
        // file-loaded 之后**下一条**就是普通属性事件：中间没有 tracksChanged。
        await engine.handle(.property(id: MpvEventMapping.pausedID, value: .flag(true)))
        let next = await iterator.next()
        #expect(next == .stateChanged(.paused))
    }

    @Test("纯工具：轨道取值与数值格式")
    func helpers() {
        #expect(MpvEngine.trackValue(.auto) == "auto")
        #expect(MpvEngine.trackValue(.disabled) == "no")
        #expect(MpvEngine.trackValue(.index(7)) == "7")
        #expect(MpvEngine.number(90) == "90.000")
        #expect(MpvEngine.number(0.5) == "0.500")
    }
}
