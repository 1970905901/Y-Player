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
/// **系统内核**用 `AVKit.VideoPlayer`；**MPV 内核**用自绘的 `MpvVideoView`（MoltenVK → Metal）、
/// **自研 FFmpeg 内核**（M04P13）用 `FFmpegVideoView`（`AVSampleBufferDisplayLayer`），
/// 都配同一条最小控制条与手势。状态区与错误提示保持不变。
@MainActor
public struct PlaybackView: View {
    /// 当前正在播的资源：**换集时会换**（见 `switchEpisode(to:)`），所以是 `@State`。
    @State var activeResource: MediaResource
    /// 当前标题（换集跟着换）。
    @State var activeTitle: String
    /// 播放设置（内核 + 解码方式）：来自设置页，**运行时严格遵循，不自动降级**。
    let settings: PlaybackSettings
    /// 进度上下文（键 + 集下标 + 展示元数据）；nil 表示不记录进度（例如从搜索页直接播放的临时场景）。
    ///
    /// 展示元数据（片名/封面/站源/线路/集名）随进度一起落库，「追剧（播放历史）」列表
    /// 就能直接渲染，不必再请求一次详情（见 ``PlaybackEntryMetadata``）。
    @State var activeProgressContext: PlaybackProgressContext?
    /// 进度存储；nil 表示不记录。
    let progressStore: PlaybackProgressStore?
    /// 播放列表（M12P1）：给了它，播放页就能自己换集（选集 / 下一集 / 片尾连播）；
    /// nil = 这页不换集（直播、下载播放、设置页试播这些入口不传）。
    let playlist: PlaybackPlaylist?
    /// 当前是第几集（换集时更新，供「选集」抽屉高亮与「下一集」判定）。
    @State private var currentEpisodeIndex: Int?
    /// 「选集」抽屉是否展开。
    @State private var isEpisodeDrawerPresented = false
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
    let onEnqueueDownloads: (([DownloadRequest], String, String, [String: String]) async -> DownloadEnqueueOutcome)?
    /// 播放信息回传口（M17P2）：读到一次**非空**的播放信息就回传一次。
    ///
    /// 上层（认识 `AppModel` 的那一层）把它记下来，诊断报告里就有「最近一次到底在播什么」——
    /// 播放页自己那份是 `@State`，退出页面就没了。
    let onPlaybackStats: ((PlaybackStats) -> Void)?

    @State var engine: (any PlayerEngine)?
    @State private var player: AVPlayer?
    /// MPV 的画面层（只有选了 MPV 才有）：引擎拿它当 `wid`，`MpvVideoView` 把它挂进画面区。
    @State private var mpvSurface: MpvVideoSurface?
    /// 自研 FFmpeg 内核的画面层（只有选了它才有）：会话往这层喂样本，`FFmpegVideoView` 把它挂进画面区。
    @State private var ffmpegSurface: FFmpegVideoSurface?
    /// 正在拖进度条：拖动期间不采纳内核报回的位置，否则滑杆会被顶回去。
    @State private var isScrubbing = false
    /// 最近一次读到的播放信息：只有报得出来的内核（MPV 与自研 FFmpeg 都认这个协议）才有这一块。
    @State var playbackStats: PlaybackStats?
    /// 内核上报的轨道（系统内核现在不上报，只有 MPV 会报，见 M03P3/M03P5）。
    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    /// 当前选中的轨道（界面态；换片时回到「自动」）。
    @State private var audioSelection: TrackSelection = .auto
    @State var subtitleSelection: TrackSelection = .auto
    /// MPV 手势：拖动开始时的基准值（手势给的是相对量）。
    @State private var gestureBasePosition: Double?
    @State private var gestureBaseVolume: Double?
    /// 手势提示条（进度预览 / 音量）；空 = 不显示。
    @State private var gestureHint = ""
    /// 当前音量（0...1）：MPV 手势改的是它；系统内核不碰（音量交给硬件键）。
    @State private var volume: Double = 1
    @State private var stateText = "准备中…"
    @State private var engineText = ""
    @State private var errorText = ""
    @State private var eventTask: Task<Void, Never>?
    @State private var resumedFromText = ""
    @State private var latestPosition: Double = 0
    @State private var latestDuration: Double = 0
    /// 当前倍速（初值在 `start()` 里从存档读；范围与预设见 ``SpeedSetting``）。
    @State private var speed: Float = SpeedSetting.normal
    /// 画面比例（M03P9）：**页面内偏好**（不落盘）—— 换页回到「适应」。
    /// 上游把 scale 存在 LiveSetting 里（按直播页）；我们没有「按页面分的播放设置」这套容器，
    /// 而一个全局落盘的值会把下一部片也按上一部选的比例放，所以先不做存档。
    @State private var scaleMode: PlaybackScaleMode = .fit
    @State private var isFinished = false
    @State private var lastPersistAt = Date.distantPast
    /// 弹幕上屏的数据（M08h）：计划 + 它用的版面。
    @State var danmakuRender: DanmakuRenderPlan?
    /// 字幕的时间轴（M09f）：把 cue 排一次序（查询是二分），别每帧重排。
    @State var subtitleTimeline: SubtitleTimeline?
    /// 内嵌字幕轨解出来的 cue（M04P19）：引擎发的是**全量**，空数组 = 没选内嵌轨 / 已关掉。
    @State var engineSubtitleCues: [SubtitleCue] = []
    /// 播放时间的外推：引擎每秒才报一次位置，直接喂给弹幕会一秒跳一格（见 ``PlaybackClock``）。
    /// 弹幕与字幕**共用**这一个时钟 —— 两者都必须按同一刻的时间取内容，各自推一份只会互相错开。
    @State private var playbackClock = PlaybackClock()
    /// 当前引擎状态（弹幕靠它决定时间走不走：暂停 / 缓冲都该停表）。
    @State var playerState: PlayerState = .idle
    /// 当前倍速（`speedChanged` 事件给的真值）。
    @State var playbackRate: Double = 1
    /// 「离线下载」那一块的反馈文案（加入队列 / 已经下过）。
    @State var downloadNotice = ""

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
        onEnqueueDownloads: (([DownloadRequest], String, String, [String: String]) async -> DownloadEnqueueOutcome)? = nil,
        onPlaybackStats: ((PlaybackStats) -> Void)? = nil,
        playlist: PlaybackPlaylist? = nil,
        onStart: (() -> Void)? = nil
    ) {
        _activeResource = State(initialValue: resource)
        _activeTitle = State(initialValue: title)
        self.settings = settings
        _activeProgressContext = State(initialValue: progressContext)
        self.playlist = playlist
        _currentEpisodeIndex = State(initialValue: playlist?.currentIndex)
        self.progressStore = progressStore
        self.danmaku = danmaku
        self.onDanmaku = onDanmaku
        self.subtitleDisplay = subtitleDisplay
        self.subtitleCues = subtitleCues
        self.danmakuLines = danmakuLines
        self.danmakuDisplay = danmakuDisplay
        self.onEnqueueDownloads = onEnqueueDownloads
        self.onPlaybackStats = onPlaybackStats
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
                if supportsPlaybackStats {
                    statsSection
                }
                if !audioTracks.isEmpty || !subtitleTracks.isEmpty {
                    tracksSection
                }
                scaleSection
                if let playlist {
                    Section("选集") {
                        Button("选集（共 \(playlist.episodes.count) 集）") {
                            isEpisodeDrawerPresented = true
                        }
                        if let next = nextEpisodeIndex {
                            Button("下一集：\(playlist.episodeName(at: next))") {
                                Task { await switchEpisode(to: next) }
                            }
                        }
                    }
                }
                Section("媒体") {
                    Text(activeResource.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if !activeResource.headers.isEmpty {
                        Text("已携带 \(activeResource.headers.count) 个请求 header")
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
                        Button("重试") {
                            Task { await retryPlayback() }
                        }
                    }
                }
            }
            .adaptiveListStyle()
            // 信息区限高：屏幕的大头留给画面（沉浸版），列表不够高时自己在内部滚动。
            .frame(maxHeight: 320)
        }
        // 外观跟随应用 / 系统（用户口径）：信息区与导航栏回落系统外观。
        // 画面区自己的黑色衬底**不跟随** —— 视频舞台在浅色下也应是黑的（跟随的是页面，不是画面）。
        .navigationTitle(activeTitle)
        // 播放页同样登记为沉浸页；详情 → 播放会叠两层，登记簿按计数算（见 Platform/AdaptiveTabBar.swift）。
        .immersiveTabBarPage()
        .sheet(isPresented: $isEpisodeDrawerPresented) {
            if let playlist {
                EpisodeListDrawer(episodes: playlist.episodes, currentIndex: currentEpisodeIndex) { index in
                    isEpisodeDrawerPresented = false
                    Task { await switchEpisode(to: index) }
                }
                // 与详情页的抽屉同一形态：半屏（iOS 15 回落整页）。
                .adaptiveHalfSheet()
            }
        }
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
        if player != nil || mpvSurface != nil || ffmpegSurface != nil {
            GeometryReader { proxy in
                ZStack {
                    // 纯黑衬底：视频按 aspect-fit 居中，留边永远是黑（不是页面底色）。
                    Color.black
                    videoLayer(size: proxy.size)
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
                    // 自绘内核（MPV / 自研 FFmpeg）没有系统播放器控件：补一条最小控制条。
                    if mpvSurface != nil || ffmpegSurface != nil {
                        playerControls
                    }
                    // 手势提示（进度预览 / 音量）：只显示、不拦触摸。
                    if !gestureHint.isEmpty {
                        Text(gestureHint)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 24)
                            .allowsHitTesting(false)
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

    /// 画面本体：系统内核走系统播放器控件；自绘内核（MPV / 自研 FFmpeg）走各自的层宿主视图。
    ///
    /// 手势**只挂在自绘内核这边**：系统内核的画面是 `VideoPlayer`，它自带一整套手势，
    /// 我们再叠一层只会互相打架（M02P15 的「长按临时加速」不做，同一条理由）。
    @ViewBuilder
    private func videoLayer(size: CGSize) -> some View {
        if let player {
            VideoPlayer(player: player)
        } else if let mpvSurface {
            interactiveLayer(MpvVideoView(surface: mpvSurface), size: size)
        } else if let ffmpegSurface {
            interactiveLayer(FFmpegVideoView(surface: ffmpegSurface), size: size)
        }
    }

    /// 自绘内核画面的共同外壳：双击播放 / 暂停 + 拖动手势。
    private func interactiveLayer(_ content: some View, size: CGSize) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // 双击 = 播放 / 暂停。
                Task { await togglePlayback() }
            }
            .gesture(playerGesture(width: size.width))
    }

    /// 自绘内核画面上的手势：
    /// - **双击**：播放 / 暂停（上面那条）；
    /// - **横向拖**：调进度 —— 拖动中只显示预览，**松手才 seek**（一次拖动几十个中间值，
    ///   逐个 seek 会把内核打爆）；换算固定为「拖满一屏宽 ≈ 120 秒」；
    /// - **纵向拖**：音量 —— 向上加、向下减，200pt 满量程，松手下发内核。
    private func playerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    let base = gestureBasePosition ?? latestPosition
                    gestureBasePosition = base
                    let target = seekTarget(base: base, dx: dx, width: width)
                    gestureHint = "\(Self.timeText(target)) / \(Self.timeText(latestDuration))"
                } else {
                    let base = gestureBaseVolume ?? volume
                    gestureBaseVolume = base
                    volume = min(max(base - Double(dy) / Self.volumePointsForFullRange, 0), 1)
                    gestureHint = "音量 \(Int((volume * 100).rounded()))%"
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy), let base = gestureBasePosition {
                    let target = seekTarget(base: base, dx: dx, width: width)
                    Task { await engine?.seek(to: target) }
                } else if gestureBaseVolume != nil {
                    let target = Float(volume)
                    Task { await engine?.setVolume(target) }
                }
                gestureBasePosition = nil
                gestureBaseVolume = nil
                gestureHint = ""
            }
    }

    /// 把「横向拖了多少」换算成目标秒数（夹在 0...总时长）。
    private func seekTarget(base: Double, dx: CGFloat, width: CGFloat) -> Double {
        let delta = Double(dx / max(width, 1)) * Self.seekSecondsPerScreen
        return min(max(base + delta, 0), max(latestDuration, 0))
    }

    /// 手势换算常量：拖满一屏宽 ≈ 120 秒；纵向 200pt 满量程音量。
    static let seekSecondsPerScreen: Double = 120
    static let volumePointsForFullRange: Double = 200

    /// 自绘内核的最小控制条：播放 / 暂停 + 进度 + 时间。
    ///
    /// 为什么必须自绘：系统内核的控件是 `VideoPlayer` 自带的，自绘内核这边只有一层画面层 ——
    /// 没有这条，用户就只能看，不能停、不能拖。变速不在这里（在信息区的「播放速度」）。
    private var playerControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button {
                    Task { await togglePlayback() }
                } label: {
                    Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playerState.isPlaying ? "暂停" : "播放")

                Text(Self.timeText(latestPosition))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Slider(
                    value: seekBinding,
                    in: 0 ... max(latestDuration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        guard !editing else { return }
                        // 松手才 seek：一次拖动会产生几十个中间值，逐个 seek 会把内核打爆。
                        let target = latestPosition
                        Task { await engine?.seek(to: target) }
                    }
                )
                .tint(.white)
                Text(Self.timeText(latestDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45))
        }
    }

    /// 进度条绑定：拖动只改界面上的位置（松手才真 seek，见 ``playerControls`` 的 `onEditingChanged`）。
    private var seekBinding: Binding<Double> {
        Binding(
            get: { latestPosition },
            set: { newValue in latestPosition = newValue }
        )
    }

    /// 播放 / 暂停（MPV 控制条）。
    private func togglePlayback() async {
        guard let engine else {
            return
        }
        if playerState.isPlaying {
            await engine.pause()
        } else {
            await engine.play()
        }
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
        guard !activeResource.url.isEmpty else {
            errorText = "播放地址为空"
            return
        }
        // 画面层要在建引擎**之前**准备好：MPV 的 `wid` 是启动期选项、自研 FFmpeg 的层是会话的落点
        // （见 `LibmpvSession` / `FFmpegSession.make(surface:)`），都得在会话建起来之前交出去。
        var videoSurface: MpvVideoSurface?
        if settings.engine == .mpv {
            let surface = MpvVideoSurface()
            videoSurface = surface
            mpvSurface = surface
        }
        var ffmpegVideoSurface: FFmpegVideoSurface?
        if settings.engine == .ffmpeg {
            let surface = FFmpegVideoSurface()
            ffmpegVideoSurface = surface
            ffmpegSurface = surface
        }
        guard let created = coordinator.makeEngine(
            kind: settings.engine,
            decoderMode: settings.decoderMode,
            videoSurface: videoSurface,
            ffmpegSurface: ffmpegVideoSurface
        ) else {
            errorText = "\(settings.engine.displayName) 内核当前不可用，无法播放（不会自动切换其他内核）。"
            return
        }

        engine = created
        if let systemEngine = created as? AVPlayerEngine {
            player = systemEngine.systemPlayer()
        }
        eventTask = Task { await consume(created) }

        do {
            // 续播：有进度记录就从上次位置起播（已看完或过短会从头，规则在 PlaybackProgress.resumePosition）。
            try await created.load(resumableResource())
            await created.play()
            // 套用存档里的倍速：必须在加载**之后**设 —— 引擎在 `load` 时会回到正常速度
            // （倍速属「本次播放的偏好」，引擎不跨资源记忆，见 `AVPlayerEngine.requestedRate`）。
            await created.setRate(speed)
        } catch let error as PlayerError {
            errorText = error.message
        } catch {
            errorText = error.localizedDescription
        }
    }

    func consume(_ engine: any PlayerEngine) async {
        for await event in engine.events {
            switch event {
            case let .stateChanged(state):
                stateText = describe(state)
                playerState = state
                // 失败要同时上那块醒目的提示：只写「状态」行容易让人以为还在转圈
                // （自研内核「选硬解但这台机器没有硬解」就走这条路，M04P14）。
                if case let .failed(reason) = state {
                    errorText = reason
                }
                if state == .playing {
                    // 起播后读一次播放信息：等一小会儿 —— MPV 的 `video-params` 是 file-loaded 之后
                    // 才填上的，立刻读会拿到一排空（自研 FFmpeg 打开时就有，等这一下也不亏）。
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        await refreshPlaybackStats()
                    }
                }
                // 覆盖层：暂停 / 缓冲 / 结束都停表，继续播放再走（先外推再改速率，见 ``PlaybackClock``）。
                playbackClock.setRate(clockRate(), at: Date())
                if state == .ended {
                    isFinished = true
                    await persist(force: true)
                    // 片尾自动下一集（M12P1）：有下一集才连播；最后一集停在结束态等人。
                    if let next = nextEpisodeIndex {
                        await switchEpisode(to: next)
                    }
                } else if state == .paused {
                    await persist(force: true)
                }
            case let .error(message):
                errorText = message
            case let .timeChanged(current, duration):
                latestDuration = duration
                // 拖动进度条时不要采纳内核报回的位置：否则滑杆会被顶回去（松手才 seek）。
                if !isScrubbing {
                    latestPosition = current
                }
                // 覆盖层：把「这一刻的位置 + 倍速」一起采下来，下一次上报之前靠外推补足。
                playbackClock.sample(position: current, rate: clockRate(), at: Date())
                await persist(force: false)
            case let .speedChanged(rate):
                // 变速：**先外推再换速率** —— 直接改会把这一次上报之前已经走过的距离丢掉，弹幕往回跳。
                playbackRate = Double(rate)
                playbackClock.setRate(clockRate(), at: Date())
            case let .subtitleCues(cues):
                // 内嵌字幕轨（M04P19）：引擎发的是**全量**，这里整份替换。
                engineSubtitleCues = cues
            case let .tracksChanged(_, audio, subtitle):
                audioTracks = audio
                subtitleTracks = subtitle
                // 换片（或换轨）后旧选择作废：回到「自动」，由内核挑默认轨。
                audioSelection = .auto
                subtitleSelection = .auto
            case .bufferedChanged:
                break
            }
        }
    }

    /// 续播资源：有进度记录时把 `startPosition` 换成上次位置。
    func resumableResource() async -> MediaResource {
        guard let activeProgressContext, let progressStore,
              let saved = await progressStore.progress(for: activeProgressContext.key)
        else {
            return activeResource
        }
        let resume = saved.resumePosition()
        guard resume > 0 else {
            return activeResource
        }
        var copy = activeResource
        copy.startPosition = resume
        resumedFromText = "已从上次位置续播（\(Self.timeText(resume))）"
        return copy
    }

    /// 落一次进度（节流；`force` 用于暂停 / 播放结束 / 离开页面）。
    func persist(force: Bool) async {
        guard let activeProgressContext, let progressStore, latestPosition > 0 else {
            return
        }
        let now = Date()
        if !force, now.timeIntervalSince(lastPersistAt) < Self.persistInterval {
            return
        }
        lastPersistAt = now
        await progressStore.save(
            PlaybackProgress(
                key: activeProgressContext.key,
                position: latestPosition,
                duration: latestDuration,
                isFinished: isFinished,
                episodeIndex: activeProgressContext.episodeIndex,
                updatedAt: now,
                metadata: activeProgressContext.metadata
            )
        )
    }

    /// 从头播放：清掉进度记录并 seek 到 0。
    func restartFromBeginning() async {
        latestPosition = 0
        isFinished = false
        resumedFromText = ""
        if let activeProgressContext, let progressStore {
            await progressStore.clear(for: activeProgressContext.key)
        }
        guard let engine else {
            return
        }
        await engine.seek(to: 0)
    }

    // MARK: - 换集（M12P1）

    /// 下一集下标；没有播放列表 / 已经是最后一集 → nil。
    private var nextEpisodeIndex: Int? {
        playlist?.nextIndex(after: currentEpisodeIndex)
    }

    /// 换一集：走播放列表给的加载器，然后在**同一个引擎**上重新 load。
    ///
    /// 不重建引擎：两种内核的 `load` 都支持复用（系统内核换 `AVPlayerItem`、MPV 每次 load 重建会话）。
    /// 换集后进度上下文、标题、弹幕一起跟着换 —— 否则「上次看到」会指回旧集、弹幕还是上一集的。
    func switchEpisode(to index: Int) async {
        guard let playlist, playlist.episodes.indices.contains(index), index != currentEpisodeIndex else {
            return
        }
        guard let next = await playlist.loadResource(index) else {
            errorText = "这一集没法在播放页直接换（需要解析链的集请回详情页点它）。"
            return
        }
        currentEpisodeIndex = index
        playlist.onIndexChanged?(index)
        activeResource = next.resource
        activeProgressContext = next.progressContext
        activeTitle = next.title.isEmpty ? playlist.episodeName(at: index) : next.title
        // 新一集的界面状态：进度、轨道、提示、错误全部从零开始。
        latestPosition = 0
        latestDuration = 0
        isFinished = false
        resumedFromText = ""
        errorText = ""
        audioTracks = []
        subtitleTracks = []
        audioSelection = .auto
        subtitleSelection = .auto
        isScrubbing = false
        // 弹幕要按新集重新搜（搜索用的是集名）；没搜到就当这集没有弹幕。
        if let danmaku {
            onDanmaku?(DanmakuRequest(name: danmaku.name, episode: playlist.episodeName(at: index)))
        }
        await loadActiveResource()
    }

    /// 重试一次播放（M16P8）：引擎已经建起来就重新 load，没建起来就整条 `start()` 重走。
    func retryPlayback() async {
        errorText = ""
        if engine == nil {
            await start()
        } else {
            await loadActiveResource()
        }
    }

    /// 让当前引擎加载 `activeResource`（换集走这里；首播走 `start()`）。
    private func loadActiveResource() async {
        guard let engine else {
            return
        }
        do {
            try await engine.load(resumableResource())
            await engine.play()
            await engine.setRate(speed)
        } catch let error as PlayerError {
            errorText = error.message
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 音轨 / 字幕轨选择。
    ///
    /// **只有内核报了轨道才出现**：三个内核都会报（系统内核 M03P7、MPV M03P5、自研 FFmpeg M04P16）——
    /// 报不出来就不显示这一块，不做「点不动的假菜单」。
    /// 轨名优先用内核报的 `label`（语言 / 标题，M03P8），读不到退「音轨 <id>」。
    private var tracksSection: some View {
        Section("轨道") {
            if !audioTracks.isEmpty {
                Picker("音轨", selection: audioSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    ForEach(audioTracks) { track in
                        Text(track.label ?? "音轨 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
            if !subtitleTracks.isEmpty {
                Picker("字幕", selection: subtitleSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    Text("关闭").tag(TrackSelection.disabled)
                    ForEach(subtitleTracks) { track in
                        Text(track.label ?? "字幕 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
        }
    }

    /// 画面比例（M03P9）：只列**当前内核真的支持**的档位 —— 系统内核一档都不支持，整行不出现；
    /// 自研 FFmpeg 只有 gravity 三态（三档）。不做「点了没反应」的开关。
    @ViewBuilder private var scaleSection: some View {
        let modes = PlaybackScaleMode.supportedModes(by: settings.engine)
        if !modes.isEmpty {
            Section("画面比例") {
                Picker("画面比例", selection: scaleBinding) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        }
    }

    /// 改画面比例：记进界面态 + 立刻下发内核（`setScaleMode`）。
    private var scaleBinding: Binding<PlaybackScaleMode> {
        Binding(
            get: { scaleMode },
            set: { mode in
                scaleMode = mode
                Task { await engine?.setScaleMode(mode) }
            }
        )
    }

    /// 音轨选择：改界面态 + 立刻下发内核（`selectTrack`）。
    private var audioSelectionBinding: Binding<TrackSelection> {
        Binding(
            get: { audioSelection },
            set: { selection in
                audioSelection = selection
                Task { await engine?.selectTrack(selection, for: .audio) }
            }
        )
    }

    /// 字幕轨选择：同上。
    private var subtitleSelectionBinding: Binding<TrackSelection> {
        Binding(
            get: { subtitleSelection },
            set: { selection in
                subtitleSelection = selection
                Task { await engine?.selectTrack(selection, for: .subtitle) }
            }
        )
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
