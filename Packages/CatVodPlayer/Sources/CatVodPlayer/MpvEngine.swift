import Foundation

/// MPV 内核（libmpv）—— **M03P1 第 4 步**：会话生命周期、命令下发、事件/属性到播放语义的翻译。
///
/// **范围与「不做的部分」（重要，别误以为能用了）**：
/// - 本引擎实装的是「加载 / 播放 / 暂停 / 跳转 / 倍速 / 轨道选择 / 进度 / 状态」这一套；
///   **画面输出（渲染路径）还没定** —— 第 3 步要在 Mac/真机上先做 SW / MoltenVK / GL 三选一的 PoC。
///   所以 ``MpvAvailability/isVideoOutputReady`` 仍是 false，`PlayerEngineKind.mpv.isAvailable` 仍是 false：
///   界面不会宣称一个「能播但没画面」的内核可用（正是 M03P1 修正过的那条语义）。
/// - 真正的 C 调用在 ``MpvSession`` 的实装（`LibmpvSession`）里；这里只对着 seam 编程，
///   于是状态机可以用假会话在 CI 上单测（`MpvEngineTests`）—— 真机到时只补渲染那一段。
///
/// **并发**：按 `PlayerEngine` 的约定，纯 C-API 内核用 `actor`（无主线程约束）。
/// 事件循环在 actor 内跑：每轮 `mpv_wait_event` 最多阻塞 ``MpvEventMapping/eventWaitTimeout`` 秒，
/// 因此 `pause()` / `seek()` 这类命令最坏等这么久（取值理由写在超时常量上）。
public actor MpvEngine: PlayerEngine, PlaybackStatsProviding {
    nonisolated public let kind: PlayerEngineKind = .mpv
    nonisolated public let events: AsyncStream<PlayerEvent>
    /// 用户选的解码方式：`.hardware` → `hwdec=auto-safe`，`.software` → `hwdec=no`。
    nonisolated let decoderMode: DecoderMode

    /// 会话工厂（单测注假的；生产走 ``MpvSessionFactory``）。
    private let makeSession: @Sendable () -> (any MpvSession)?
    private var session: (any MpvSession)?
    private var eventLoop: Task<Void, Never>?
    private var continuation: AsyncStream<PlayerEvent>.Continuation?
    private var state: PlayerState = .idle
    private var duration: Double = 0
    /// 最近一次已知播放位置（`duration` 变化时补发的 `timeChanged` 要用）。
    private var lastTime: Double = 0
    /// 用户音量（0...1）与音量增益（1.0 = 原声）**分开记**（M04P23）：mpv 只有一只 `volume` 旋钮。
    /// 增益的范围 / 夹紧见 ``AudioGain``（上限那份账在它那儿，这里不再写一遍）。
    private var currentVolume: Float = 1
    private var currentGain: Float = 1

    public init(decoderMode: DecoderMode = .hardware, videoSurface: MpvVideoSurface? = nil) {
        self.init(
            decoderMode: decoderMode,
            makeSession: { MpvSessionFactory.make(videoSurface: videoSurface) }
        )
    }

    /// 单测入口：注入会话工厂，不碰真 libmpv。
    init(decoderMode: DecoderMode, makeSession: @escaping @Sendable () -> (any MpvSession)?) {
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
            update(.failed(PlayerError.engineUnavailable(.mpv).message))
            throw PlayerError.engineUnavailable(.mpv)
        }
        self.session = session
        configure(session, resource: resource)

        if let failure = session.initialize() {
            session.destroy()
            self.session = nil
            update(.failed(failure))
            throw PlayerError.loadFailed(failure)
        }
        for id in MpvEventMapping.observedIDs {
            guard let name = MpvEventMapping.propertyName(for: id),
                  let format = MpvEventMapping.propertyFormat(for: id)
            else { continue }
            session.observe(property: name, id: id, format: format)
        }

        update(.loading)
        if let failure = session.command(["loadfile", url.absoluteString, "replace"]) {
            update(.failed(failure))
            throw PlayerError.loadFailed(failure)
        }
        startEventLoop()
    }

    public func play() async {
        guard let session else { return }
        _ = session.command(["set", "pause", "no"])
        update(.playing)
    }

    public func pause() async {
        guard let session else { return }
        _ = session.command(["set", "pause", "yes"])
        update(.paused)
    }

    public func seek(to seconds: Double) async {
        guard let session else { return }
        let target = max(seconds, 0)
        _ = session.command(["seek", Self.number(target), "absolute"])
        lastTime = target
        emit(.timeChanged(current: target, duration: duration))
    }

    public func setRate(_ rate: Float) async {
        guard let session else { return }
        _ = session.command(["set", "speed", Self.number(Double(rate))])
        emit(.speedChanged(rate))
    }

    /// 音量：mpv 的 `volume` 属性是 0–100（100 = 原声），这里把 0...1 换算过去。
    ///
    /// 与增益（M04P23）分开记：mpv 那边只有一只 `volume` 旋钮，写它时要把两者乘起来。
    public func setVolume(_ volume: Float) async {
        currentVolume = min(max(volume, 0), 1)
        applyVolume()
    }

    /// 音量增益（M04P23）：mpv 的 `volume` 可以超过 100（这就是它的「放大」）——
    /// `volume-max` 放到 200（mpv 默认 130，不放会被削掉一半增益）。
    public func setAudioGain(_ gain: Float) async {
        currentGain = AudioGain.clamp(gain)
        guard let session else { return }
        _ = session.command(["set", "volume-max", Self.number(Double(AudioGain.maximum) * 100)])
        applyVolume()
    }

    /// 逐帧步进（M04P23）：mpv 的 `frame-step` —— **播放中调它会先暂停再走一帧**（mpv 的语义），
    /// 状态跟着报「暂停」（别让界面还以为在播）。
    public func stepFrame() async {
        guard let session else { return }
        _ = session.command(["frame-step"])
        update(.paused)
    }

    /// 把「用户音量 × 增益」一起写给 mpv（唯一的 `volume` 旋钮）。
    private func applyVolume() {
        guard let session else { return }
        let value = Double(currentVolume) * Double(currentGain) * 100
        _ = session.command(["set", "volume", Self.number(min(value, Double(AudioGain.maximum) * 100))])
    }

    public func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        guard let session else { return }
        let name = switch kind {
        case .video: "vid"
        case .audio: "aid"
        case .subtitle: "sid"
        }
        _ = session.command(["set", name, Self.trackValue(selection)])
    }

    /// 画面比例（M03P9）：三条属性一起设（见 ``PlaybackScaleMode/mpvCommands``）。
    /// mpv 的属性跨 `loadfile` 保留，所以设一次就够 —— 换片不用重下。
    public func setScaleMode(_ mode: PlaybackScaleMode) async {
        guard let session else { return }
        for command in mode.mpvCommands {
            _ = session.command(command)
        }
    }

    public func teardown() async {
        eventLoop?.cancel()
        eventLoop = nil
        session?.destroy()
        session = nil
        state = .idle
        duration = 0
        lastTime = 0
    }

    // MARK: - 内部

    /// 把 `MediaResource` 翻成 mpv 选项。**注意：一项渲染相关的都没有**（`vo` 等第 3 步定路径后加）。
    ///
    /// 必须 `initialize()` 之前调用：libmpv 的选项在初始化之后再设基本无效。
    private func configure(_ session: any MpvSession, resource: MediaResource) {
        session.setOption(name: "hwdec", value: decoderMode == .hardware ? "auto-safe" : "no")
        if resource.startPosition > 0 {
            // mpv 的 `start`（秒）。0 时不设，免得干扰内核默认行为。
            session.setOption(name: "start", value: Self.number(resource.startPosition))
        }
        if !resource.headers.isEmpty {
            // `--http-header-fields` 是**逗号分隔**的 `名: 值` 串；排序只为输出稳定（便于排查与测试）。
            let fields = resource.headers
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ",")
            session.setOption(name: "http-header-fields", value: fields)
        }
        if !resource.subtitleURLs.isEmpty {
            session.setOption(name: "sub-files", value: resource.subtitleURLs.joined(separator: ","))
        }
    }

    /// 起事件循环。
    ///
    /// - 用 `Task.detached`：这是个纯循环，**不继承** actor 隔离（继承了反而会让 `await`
    ///   变成「同隔离调用」，招来无意义的编译警告）；
    /// - `[weak self]` + 每轮 `guard let self`：引擎被释放后循环自己退出，不留空转任务；
    /// - `teardown()` 会 `cancel()` 它，所以正常情况下不用等 `waitEvent` 超时。
    private func startEventLoop() {
        eventLoop?.cancel()
        eventLoop = Task.detached { [weak self] in
            while !Task.isCancelled {
                // 每轮重新取一次引擎：它被释放后循环自己退出，不留空转任务。
                // 用局部名 `engine` 而不是 `self`：SwiftFormat 的 `redundantSelf` 要求
                // 局部绑定后再写 `self.` 是多余的（而脱开闭包时编译器又要求显式 self）—— 换个名字两边都干净。
                guard let engine = self, let event = await engine.nextEvent() else { return }
                await engine.handle(event)
            }
        }
    }

    /// 上报轨道列表（播放页「音轨 / 字幕」下拉框靠它）。
    ///
    /// 时机：`file-loaded` 之后读一次 —— 这时 mpv 已经把容器里的轨道都认出来了；
    /// 换片必然再来一次 `file-loaded`，所以不必 observe。
    /// 读 `track-list` 而不是观察它：那是**结构化属性**（node），为几行下拉框接一套 node 解析不划算。
    private func emitTrackList() {
        guard let session,
              let json = session.propertyString("track-list"),
              let tracks = MpvEventMapping.tracks(fromTrackListJSON: json)
        else {
            return
        }
        emit(.tracksChanged(video: tracks.video, audio: tracks.audio, subtitle: tracks.subtitle))
    }

    /// 取下一件事件；拿不到会话或已取消时返回 nil（循环就此结束）。
    private func nextEvent() -> MpvSessionEvent? {
        guard let session, !Task.isCancelled else { return nil }
        return session.waitEvent(timeout: MpvEventMapping.eventWaitTimeout)
    }

    /// 处理一件会话事件（**内部可见**：单测直接喂事件，与真机的事件循环共用同一套语义）。
    func handle(_ event: MpvSessionEvent) {
        switch event {
        case .none, .other, .shutdown:
            // 超时 / 不关心的事件；`shutdown` 只在我们 destroy 时出现（teardown 已把状态置回 idle）。
            break
        case .fileLoaded:
            // mpv 加载完即开始播（若用户此前按了暂停，`pause` 属性变化会把状态纠正过来）。
            update(.playing)
            emitTrackList()
        case let .endFile(reason):
            let failure = MpvEventMapping.isFailure(endFileReason: reason)
            update(failure ? .failed("播放失败（mpv 报告 \(reason)）") : .ended)
        case let .property(id, value):
            apply(effect: MpvEventMapping.effect(ofProperty: id, value: value, duration: duration))
        }
    }

    private func apply(effect: MpvPropertyEffect) {
        switch effect {
        case let .time(current, duration):
            lastTime = current
            emit(.timeChanged(current: current, duration: duration))
        case let .duration(seconds):
            duration = seconds
            emit(.timeChanged(current: lastTime, duration: seconds))
        case let .paused(paused):
            // 加载途中来的 `pause` 变化先忽略：等 `file-loaded` 再定状态，
            // 否则会出现「还没加载完就显示播放中」。
            guard state == .playing || state == .paused else { return }
            update(paused ? .paused : .playing)
        case .ignore:
            break
        }
    }

    /// 读一次播放信息（M4 前置）：**属性名是 mpv 的**，拼装规则在 ``PlaybackStats``（纯逻辑，有单测）。
    ///
    /// 走 `propertyString` 逐个读、不用属性观察：这是**按需快照**（起播后自动读一次、用户也能点「刷新」），
    /// 不是逐帧较劲的实时面板。属性不存在（本地文件没有码率等）就当没读到。
    public func playbackStats() async -> PlaybackStats {
        guard let session else {
            return PlaybackStats()
        }
        var raw: [String: String] = [:]
        for name in Self.statsPropertyNames {
            if let value = session.propertyString(name) {
                raw[name] = value
            }
        }
        return PlaybackStats(rawValues: raw)
    }

    /// 要读的属性（名字对齐 mpv 的 property list）。
    ///
    /// 只收「回答一个具体问题」的那些：这一路是什么（分辨率 / 编码 / 色彩）、
    /// 硬解到底生效没有（`hwdec-current`）、跑得好不好（码率 / 丢帧）。
    private static let statsPropertyNames = [
        "video-params/w",
        "video-params/h",
        "file-format",
        "video-format",
        "video-params/pixelformat",
        "audio-codec",
        "audio-params/channel-count",
        "audio-params/samplerate",
        "container-fps",
        "video-params/primaries",
        "video-params/gamma",
        "video-out-params/primaries",
        "video-out-params/gamma",
        "video-out-params/pixelformat",
        "hwdec-current",
        "video-bitrate",
        "frame-drop-count",
        "decoder-frame-drop-count",
    ]

    /// 轨道选择 → mpv 的值（禁用是 `no`，自动是 `auto`，指定轨道是轨道 id）。
    static func trackValue(_ selection: TrackSelection) -> String {
        switch selection {
        case .auto: "auto"
        case .disabled: "no"
        case let .index(value): String(value)
        }
    }

    /// 数值参数：固定 3 位小数，让命令串稳定（便于排查与测试断言）。
    static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func update(_ newState: PlayerState) {
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PlayerEvent) {
        continuation?.yield(event)
    }
}

/// 画面比例 → mpv 属性的纯映射（M03P9）。
///
/// 单独成扩展而不是写进引擎类体：它**不是**引擎的状态/行为，是「档位 → 属性」的映射。
extension PlaybackScaleMode {
    /// 画面比例落到 mpv 的三条属性（M03P9，纯函数、有单测）：
    /// - `video-aspect-override`：`no`（按容器）/ `16:9` / `4:3`；
    /// - `panscan`：`0`（不裁）/ `1.0`（裁剪铺满）；
    /// - `keepaspect`：`yes`（保比例）/ `no`（拉伸铺满）。
    ///
    /// **每次把三条都设一遍**：只设「变的那条」会在切档时留下上一档的残留
    /// （比如裁剪完切回适应，`panscan` 还停在 1）。
    var mpvCommands: [[String]] {
        switch self {
        case .fit:
            [
                ["set", "video-aspect-override", "no"],
                ["set", "panscan", "0"],
                ["set", "keepaspect", "yes"],
            ]
        case .ratio16x9:
            [
                ["set", "video-aspect-override", "16:9"],
                ["set", "panscan", "0"],
                ["set", "keepaspect", "yes"],
            ]
        case .ratio4x3:
            [
                ["set", "video-aspect-override", "4:3"],
                ["set", "panscan", "0"],
                ["set", "keepaspect", "yes"],
            ]
        case .crop:
            [
                ["set", "video-aspect-override", "no"],
                ["set", "panscan", "1.0"],
                ["set", "keepaspect", "yes"],
            ]
        case .stretch:
            [
                ["set", "video-aspect-override", "no"],
                ["set", "panscan", "0"],
                ["set", "keepaspect", "no"],
            ]
        }
    }
}
