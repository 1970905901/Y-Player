import AVKit
import CatVodCore
import CatVodPlayer
import CatVodStore
import Foundation
import SwiftUI

/// 播放页。
///
/// 使用**系统原生播放器 UI**（`AVKit.VideoPlayer`）承载 `.system` 内核：
/// 按 `docs/UI 规范.md`，各系统版本使用各自的原生控件与手势，不自绘播放控件。
/// MPV / 自研 FFmpeg 内核（M3/M4）接入后会替换中间的渲染视图，状态区与错误提示保持不变。
@MainActor
public struct PlaybackView: View {
    let resource: MediaResource
    let title: String
    /// 播放设置（内核 + 解码方式）：来自设置页，**运行时严格遵循，不自动降级**。
    let settings: PlaybackSettings
    /// 进度上下文（键 + 集下标 + 展示元数据）；nil 表示不记录进度（例如从搜索页直接播放的临时场景）。
    ///
    /// 展示元数据（片名/封面/站源/线路/集名）随进度一起落库，「追剧（播放历史）」列表
    /// 就能直接渲染，不必再请求一次详情（见 ``PlaybackEntryMetadata``）。
    let progressContext: PlaybackProgressContext?
    /// 进度存储；nil 表示不记录。
    let progressStore: PlaybackProgressStore?
    /// 「开始一次播放」的回传口（M06l）：换集/换台时上层用它把跨集累计的东西归零（当前用于「跳过广告」统计）。
    ///
    /// 为什么不让播放页直接拿 `AppModel`：这里只需要「播了」这一个信号，
    /// 传一个闭包比把整个模型塞进播放页（6 个调用点都得跟着改）更小、也更好测。
    let onStart: (() -> Void)?
    /// 这次要搜的弹幕（M08c）；nil = 这个入口不放弹幕（直播、临时播放等）。
    let danmaku: DanmakuRequest?
    /// 弹幕请求的回传口：播放页不认识接口配置，把「搜什么」交给上层（`AppModel.loadDanmaku`）。
    let onDanmaku: ((DanmakuRequest) -> Void)?
    /// 字幕显示设置（在播页只画，不认识 `AppModel`）。由上层传值 —— 见 PlaybackView 顶部说明。
    let subtitleDisplay: SubtitleDisplayConfig
    /// 字幕 cue 列表。
    let subtitleCues: [SubtitleCue]
    /// 弹幕行。
    let danmakuLines: [DanmakuLine]
    /// 弹幕显示设置。
    let danmakuDisplay: DanmakuDisplayConfig
    /// 批量下载：把要下载的集交回上层（只有上层知道站点与 `AppModel`）。
    let onEnqueueDownloads: (([DownloadRequest], String, String, [String: String]) async -> Int)?

    @State private var engine: AVPlayerEngine?
    @State private var player: AVPlayer?
    @State private var stateText = "准备中…"
    @State private var engineText = ""
    @State private var errorText = ""
    @State private var eventTask: Task<Void, Never>?
    @State private var resumedFromText = ""
    @State private var latestPosition: Double = 0
    @State private var latestDuration: Double = 0
    /// 当前倍速（初值在 `start()` 里从存档读；范围与预设见 ``SpeedSetting``）。
    @State private var speed: Float = SpeedSetting.normal
    @State private var isFinished = false
    @State private var lastPersistAt = Date.distantPast
    /// 弹幕上屏的数据（M08h）：计划 + 它用的版面。
    @State private var danmakuRender: DanmakuRenderPlan?
    /// 字幕的时间轴（M09f）：把 cue 排一次序（查询是二分），别每帧重排。
    @State private var subtitleTimeline: SubtitleTimeline?
    /// 播放时间的外推：引擎每秒才报一次位置，直接喂给弹幕会一秒跳一格（见 ``PlaybackClock``）。
    /// 弹幕与字幕**共用**这一个时钟 —— 两者都必须按同一刻的时间取内容，各自推一份只会互相错开。
    @State private var playbackClock = PlaybackClock()
    /// 当前引擎状态（弹幕靠它决定时间走不走：暂停 / 缓冲都该停表）。
    @State private var playerState: PlayerState = .idle
    /// 当前倍速（`speedChanged` 事件给的真值）。
    @State private var playbackRate: Double = 1
    /// 「离线下载」那一块的反馈文案（加入队列 / 已经下过）。
    @State private var downloadNotice = ""

    /// 进度落库节流间隔（秒）：播放中不必每秒写一次。
    static let persistInterval: TimeInterval = 5

    public init(
        resource: MediaResource,
        title: String,
        settings: PlaybackSettings = PlaybackSettings(),
        progressContext: PlaybackProgressContext? = nil,
        progressStore: PlaybackProgressStore? = nil,
        danmaku: DanmakuRequest? = nil,
        onDanmaku: ((DanmakuRequest) -> Void)? = nil,
        subtitleDisplay: SubtitleDisplayConfig = SubtitleDisplayConfig(),
        subtitleCues: [SubtitleCue] = [],
        danmakuLines: [DanmakuLine] = [],
        danmakuDisplay: DanmakuDisplayConfig = DanmakuDisplayConfig(),
        onEnqueueDownloads: (([DownloadRequest], String, String, [String: String]) async -> Int)? = nil,
        onStart: (() -> Void)? = nil
    ) {
        self.resource = resource
        self.title = title
        self.settings = settings
        self.progressContext = progressContext
        self.progressStore = progressStore
        self.danmaku = danmaku
        self.onDanmaku = onDanmaku
        self.subtitleDisplay = subtitleDisplay
        self.subtitleCues = subtitleCues
        self.danmakuLines = danmakuLines
        self.danmakuDisplay = danmakuDisplay
        self.onEnqueueDownloads = onEnqueueDownloads
        self.onStart = onStart
    }

    public var body: some View {
        VStack(spacing: 0) {
            playerArea
            List {
                Section("离线下载") {
                    Button("下载本集") {
                        Task { await enqueueDownload() }
                    }
                    if !downloadNotice.isEmpty {
                        Text(downloadNotice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("播放状态") {
                    InfoRow(title: "状态", value: stateText)
                    if !engineText.isEmpty {
                        InfoRow(title: "内核", value: engineText)
                    }
                }
                Section("媒体") {
                    Text(resource.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if !resource.headers.isEmpty {
                        Text("已携带 \(resource.headers.count) 个请求 header")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if engine != nil {
                    speedSection
                }
                if !resumedFromText.isEmpty {
                    Section("进度") {
                        Text(resumedFromText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("从头播放") {
                            Task { await restartFromBeginning() }
                        }
                    }
                }
                if !errorText.isEmpty {
                    Section("错误") {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .adaptiveListStyle()
            // 信息区限高：屏幕的大头留给画面（沉浸版），列表不够高时自己在内部滚动。
            .frame(maxHeight: 320)
        }
        // 外观跟随应用 / 系统（用户口径）：信息区与导航栏回落系统外观。
        // 画面区自己的黑色衬底**不跟随** —— 视频舞台在浅色下也应是黑的（跟随的是页面，不是画面）。
        .navigationTitle(title)
        // 播放页也不该看到底部 Tab 栏：播放链路每一层都收起（进入详情页起就没了，见 Platform/AdaptiveTabBar.swift）。
        .adaptiveTabBarHidden(true)
        .task {
            // 「开始一次播放」的回传口（M06l）：换集/换台时上层用它把「跳过广告」的累计统计归零。
            onStart?()
            // 弹幕（M08c）：把「搜什么」交给上层 —— 播放页不认识接口配置，也不该认识。
            if let danmaku {
                onDanmaku?(danmaku)
            }
            await start()
        }
        .onDisappear {
            eventTask?.cancel()
            eventTask = nil
            let current = engine
            Task {
                // 退出前落一次进度（节流不适用于离场）。
                await persist(force: true)
                await current?.teardown()
            }
        }
    }

    @ViewBuilder
    private var playerArea: some View {
        if let player {
            GeometryReader { proxy in
                ZStack {
                    // 纯黑衬底：视频按 aspect-fit 居中，留边永远是黑（不是页面底色）。
                    Color.black
                    VideoPlayer(player: player)
                    // 弹幕层（M08h）：只在有计划时挂上去 —— 没开弹幕 / 这集没搜到时
                    // 连这一层都不存在，不占渲染开销。
                    if let danmakuRender {
                        DanmakuOverlay(
                            plan: danmakuRender.plan,
                            style: danmakuRender.style,
                            clock: playbackClock
                        )
                        .clipped()
                    }
                    // 字幕层（M09f）：与弹幕同一套 —— 没有 cue、或用户关掉了字幕时，整层不存在。
                    // 放在弹幕**之后**（= 画在弹幕上层）：字幕是要读的，不该被弹幕盖住。
                    // 显示设置不参与时间轴的构建（没有几何烘进去），所以改字号 / 位置不用重排 ——
                    // 这点与弹幕相反（弹幕的字号会影响计划里量出来的文本宽度）。
                    if subtitleDisplay.isVisible, let subtitleTimeline, !subtitleTimeline.isEmpty {
                        SubtitleOverlay(
                            timeline: subtitleTimeline,
                            style: subtitleDisplay.style.resolved(height: Double(proxy.size.height)),
                            clock: playbackClock
                        )
                        .clipped()
                    }
                }
                // 键里带尺寸：旋转屏幕 / 改窗口后，轨道数与字号要按新尺寸重排。
                .task(id: danmakuPlanKey(size: proxy.size)) {
                    danmakuRender = makeDanmakuRender(size: proxy.size)
                }
                // 字幕的时间轴不依赖尺寸（没有几何烘进去），键只看 cue 本身。
                .task(id: subtitleTimelineKey) {
                    subtitleTimeline = makeSubtitleTimeline()
                }
            }
            // 沉浸版：画面区吃掉信息区之外的全部高度 —— 竖屏视频因此能铺满大半屏，
            // 不再是顶部一条 16:9 的横带（那正是「白底边」的来源）。
            // 下限 280：横屏（可用高约 350）时把信息区压到内部滚动，画面不被挤出屏幕。
            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        }
    }

    // MARK: - 覆盖层（弹幕 M08h / 字幕 M09f）

    /// 字幕时间轴的重排键：**只看 cue 本身**（不像弹幕还要带尺寸与显示设置 —— 字幕没有几何
    /// 烘进时间轴，字号与位置只在画的时候用）。
    ///
    /// 与 `danmakuPlanKey` 同一套理由：用「条数 + 首末开始时间」代表整份数组，
    /// 每帧都要算的键不该是 O(n)。
    private var subtitleTimelineKey: String {
        let cues = subtitleCues
        return [
            String(cues.count),
            String(cues.first?.start ?? -1),
            String(cues.last?.start ?? -1),
        ].joined(separator: "|")
    }

    /// 建一次字幕时间轴。
    ///
    /// 比弹幕的计划便宜得多（排序 + 算最长时长），但仍是 O(n log n)：放进 `.task(id:)` 而不是
    /// 每次 body 都算 —— 播放中 body 会因时钟、状态、进度反复重建。
    private func makeSubtitleTimeline() -> SubtitleTimeline? {
        let cues = subtitleCues
        guard !cues.isEmpty else {
            return nil
        }
        return SubtitleTimeline(cues: cues)
    }

    /// 计划重排的触发键：**行内容 / 画面尺寸 / 显示设置**任一变化都要重排。
    ///
    /// 行内容用「条数 + 首末时间」代表，而不是整份数组：比较几万条是 O(n)，而这个键每帧都要算；
    /// 换集时三者几乎必然一起变，够用（同一集重复加载同一份弹幕时结果也一样，不必重排）。
    private func danmakuPlanKey(size: CGSize) -> String {
        let lines = danmakuLines
        return [
            String(lines.count),
            String(lines.first?.time ?? -1),
            String(lines.last?.time ?? -1),
            String(Int(size.width.rounded())),
            String(Int(size.height.rounded())),
            // 显示设置也要进键：字号影响宽度度量、区域影响轨道数，两者都已经烘进计划本身了。
            danmakuDisplay.persistenceValue,
        ].joined(separator: "|")
    }

    /// 排一次计划。
    ///
    /// **只在键变化时跑**：它是 O(行数 × 轨道数) 外加一次全量文本度量（几万条弹幕在设备上
    /// 是几十毫秒量级）；每帧重排会把播放拖垮。
    ///
    /// 宽度度量走 ``AdaptiveFontMetrics``（平台字体），字号从**同一份**解好的 `style` 取 ——
    /// 量宽度与排轨道必须对得上。
    private func makeDanmakuRender(size: CGSize) -> DanmakuRenderPlan? {
        let lines = danmakuLines
        guard !lines.isEmpty, size.width > 1, size.height > 1 else {
            return nil
        }
        let style = danmakuDisplay.style.resolved(
            width: Double(size.width),
            height: Double(size.height)
        )
        let plan = DanmakuPlan(lines: lines, layout: style.layout) { line in
            AdaptiveFontMetrics.width(of: line.text, size: style.fontSize(of: line))
        }
        return DanmakuRenderPlan(plan: plan, style: style)
    }

    /// 现在该不该走表：只认 `playing` —— 暂停、缓冲、结束、失败都必须停住，
    /// 否则「缓冲时弹幕还在划」这种假象会让人以为卡的是弹幕而不是网。
    ///
    /// 弹幕与字幕共用它：两者都必须跟画面同一刻。
    private func clockRate() -> Double {
        playerState == .playing ? playbackRate : 0
    }

    // MARK: - 离线下载（M10f）

    /// 把这一集加进下载队列。
    ///
    /// 三处取值的理由：
    /// - **站点 key** 从 `progressContext` 取 —— 播放页本来就不认识站点配置，
    ///   进度上下文是它手上唯一「这一集是谁」的线索；
    /// - **片名 / 集名** 优先用弹幕请求里的那两个字段：那是上层拼好的可搜索名字，
    ///   比播放页标题准（标题常带「 · 线路」这类后缀，写进文件名会很难看）；
    /// - **请求头** 直接用 `resource.headers`：与播放本身同一套（站点鉴权都在里面），
    ///   下载时缺一个 header 就会 403。
    /// 交给上层下载。
    ///
    /// 播放页不认识 `AppModel`（见文件顶部的设计说明），下载队列只有上层知道；
    /// `onEnqueueDownloads` 为 nil 表示当前上下文不支持下载，返回 -1 让调用方给提示。
    private func enqueueViaUpperLayer(
        _ requests: [DownloadRequest],
        siteKey: String,
        title: String
    ) async -> Int {
        guard let onEnqueueDownloads else {
            return -1
        }
        return await onEnqueueDownloads(requests, siteKey, title, resource.headers)
    }

    private func enqueueDownload() async {
        let request = DownloadRequest(
            episode: danmaku?.episode ?? title,
            line: "",
            url: resource.url
        )
        let added = await enqueueViaUpperLayer(
            [request],
            siteKey: progressContext?.key.siteKey ?? "",
            title: danmaku?.name ?? title
        )
        downloadNotice = added == 0
            ? "这一集已经在下载列表里了（同站点 + 同名 + 同集只下一次）。"
            : "已加入下载队列 —— 去「设置 → 数据 → 下载管理」看进度。"
    }
}

// MARK: - 启动与事件

extension PlaybackView {
    func start() async {
        guard engine == nil else {
            return
        }
        let coordinator = PlayerCoordinator()
        engineText = settings.engine.displayName
        speed = PlaybackSpeedBook.speed()
        // 弹幕倍速的初值：`speedChanged` 事件不一定在起播时发（引擎本来就是这个速度时它不会变），
        // 所以这里先把用户设的倍速当作真值用起来。
        playbackRate = Double(speed)

        // 策略：严格按用户设置执行，**不自动降级**。不可用就提示，让用户改设置。
        if case let .unavailable(kind, reason) = coordinator.resolve(settings: settings) {
            errorText = "\(kind.displayName)：\(reason)\n请到「接口 → 播放设置」更换内核。"
            return
        }
        guard !resource.url.isEmpty else {
            errorText = "播放地址为空"
            return
        }
        guard let created = coordinator.makeEngine(kind: settings.engine, decoderMode: settings.decoderMode) else {
            errorText = "\(settings.engine.displayName) 内核尚未实现，无法播放（不会自动切换其他内核）。"
            return
        }
        guard let systemEngine = created as? AVPlayerEngine else {
            errorText = "当前播放页仅接入了系统播放内核。"
            return
        }

        engine = systemEngine
        player = systemEngine.systemPlayer()
        eventTask = Task { await consume(systemEngine) }

        do {
            // 续播：有进度记录就从上次位置起播（已看完或过短会从头，规则在 PlaybackProgress.resumePosition）。
            try await systemEngine.load(resumableResource())
            await systemEngine.play()
            // 套用存档里的倍速：必须在加载**之后**设 —— 引擎在 `load` 时会回到正常速度
            // （倍速属「本次播放的偏好」，引擎不跨资源记忆，见 `AVPlayerEngine.requestedRate`）。
            await systemEngine.setRate(speed)
        } catch let error as PlayerError {
            errorText = error.message
        } catch {
            errorText = error.localizedDescription
        }
    }

    func consume(_ engine: AVPlayerEngine) async {
        for await event in engine.events {
            switch event {
            case let .stateChanged(state):
                stateText = describe(state)
                playerState = state
                // 覆盖层：暂停 / 缓冲 / 结束都停表，继续播放再走（先外推再改速率，见 ``PlaybackClock``）。
                playbackClock.setRate(clockRate(), at: Date())
                if state == .ended {
                    isFinished = true
                    await persist(force: true)
                } else if state == .paused {
                    await persist(force: true)
                }
            case let .error(message):
                errorText = message
            case let .timeChanged(current, duration):
                latestPosition = current
                latestDuration = duration
                // 覆盖层：把「这一刻的位置 + 倍速」一起采下来，下一次上报之前靠外推补足。
                playbackClock.sample(position: current, rate: clockRate(), at: Date())
                await persist(force: false)
            case let .speedChanged(rate):
                // 变速：**先外推再换速率** —— 直接改会把这一次上报之前已经走过的距离丢掉，弹幕往回跳。
                playbackRate = Double(rate)
                playbackClock.setRate(clockRate(), at: Date())
            case .bufferedChanged, .tracksChanged:
                break
            }
        }
    }

    /// 续播资源：有进度记录时把 `startPosition` 换成上次位置。
    func resumableResource() async -> MediaResource {
        guard let progressContext, let progressStore, let saved = await progressStore.progress(for: progressContext.key) else {
            return resource
        }
        let resume = saved.resumePosition()
        guard resume > 0 else {
            return resource
        }
        var copy = resource
        copy.startPosition = resume
        resumedFromText = "已从上次位置续播（\(Self.timeText(resume))）"
        return copy
    }

    /// 落一次进度（节流；`force` 用于暂停 / 播放结束 / 离开页面）。
    func persist(force: Bool) async {
        guard let progressContext, let progressStore, latestPosition > 0 else {
            return
        }
        let now = Date()
        if !force, now.timeIntervalSince(lastPersistAt) < Self.persistInterval {
            return
        }
        lastPersistAt = now
        await progressStore.save(
            PlaybackProgress(
                key: progressContext.key,
                position: latestPosition,
                duration: latestDuration,
                isFinished: isFinished,
                episodeIndex: progressContext.episodeIndex,
                updatedAt: now,
                metadata: progressContext.metadata
            )
        )
    }

    /// 从头播放：清掉进度记录并 seek 到 0。
    func restartFromBeginning() async {
        latestPosition = 0
        isFinished = false
        resumedFromText = ""
        if let progressContext, let progressStore {
            await progressStore.clear(for: progressContext.key)
        }
        guard let engine else {
            return
        }
        await engine.seek(to: 0)
    }

    /// 「播放速度」区：当前值 + 预设 + 恢复。
    ///
    /// 排版跟本页其它区一致（一行行文字），因为画面交给系统原生 `VideoPlayer`，我们不自绘播放控件
    /// （`docs/UI 规范.md`）。范围/步进/预设与显示格式全部对齐上游 `SpeedSetting`；
    /// 上游那套的「长按倍速」「跳过静音」不改（前者是手势、后者要内核支持，见 M02P15）。
    private var speedSection: some View {
        Section("播放速度") {
            HStack {
                Text(SpeedSetting.format(speed))
                    .monospacedDigit()
                Spacer()
                Button("恢复 1.0x") {
                    setSpeed(SpeedSetting.normal, persist: true)
                }
                .disabled(SpeedSetting.isNormal(speed))
            }
            Slider(
                value: speedSlider,
                in: SpeedSetting.minimum ... SpeedSetting.maximum,
                step: SpeedSetting.step,
                onEditingChanged: { editing in
                    // 拖动过程中已经即时生效；松手才落盘（一次拖动几十个中间值，不必写几十次 UserDefaults）。
                    guard !editing else { return }
                    PlaybackSpeedBook.save(speed)
                }
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SpeedSetting.presets, id: \.self) { preset in
                        Button(SpeedSetting.format(preset)) {
                            setSpeed(preset, persist: true)
                        }
                        .buttonStyle(.bordered)
                        .tint(SpeedSetting.isSame(preset, speed) ? .accentColor : .secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 滑杆绑定：拖动中即时生效（改倍速要能马上听出来）。
    private var speedSlider: Binding<Float> {
        Binding(
            get: { speed },
            set: { newValue in setSpeed(newValue, persist: false) }
        )
    }

    /// 改倍速的**唯一出口**：夹紧 → 记进界面 →（可选）落盘 → 下发内核。
    private func setSpeed(_ value: Float, persist: Bool) {
        let target = SpeedSetting.clamp(value)
        speed = target
        if persist {
            PlaybackSpeedBook.save(target)
        }
        guard let engine else {
            return
        }
        Task { await engine.setRate(target) }
    }

    /// 时间文本（`1:02:03` 或 `2:34`）。
    static func timeText(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    func describe(_ state: PlayerState) -> String {
        switch state {
        case .idle: "空闲"
        case .loading: "加载中"
        case .playing: "播放中"
        case .paused: "已暂停"
        case .buffering: "缓冲中"
        case .ended: "播放结束"
        case let .failed(reason): "失败：\(reason)"
        }
    }
}
