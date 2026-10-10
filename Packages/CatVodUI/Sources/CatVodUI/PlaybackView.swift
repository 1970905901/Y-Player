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
    /// 播放页自己的换线路能力（M03P17）：详情页把「线路清单 + 另一条线路上的那一集怎么取」包好传进来。
    /// `nil`（拿不到线路清单 / 只有一条线）= 不显示线路区。
    let lineSwitcher: PlaybackLineSwitcher?
    /// 当前是第几集（换集时更新，供「选集」抽屉高亮与「下一集」判定）。
    /// 去掉 `private`：`PlaybackView+Lines.swift`（换线路）要用。
    @State var currentEpisodeIndex: Int?
    /// 「选集」抽屉是否展开。
    @State private var isEpisodeDrawerPresented = false
    /// 当前线路（M03P17）：起手是详情页选的那条，换线路后就地更新。
    @State var selectedLine = ""
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
    /// 弹幕总开关的回写口（M03P18）：nil = 上层不给改（那就不摆这个开关）。
    let onToggleDanmaku: ((Bool) -> Void)?
    /// 这次播放的来源行（「解析：xxx」/ 站点给的 desc，M03P22）：空数组 = 不显示。
    /// 由上层从 `AppModel.playbackInfoRows` 传进来（播放页不认识 `AppModel`）。
    let playbackInfoRows: [String]
    /// 是否已收藏（M03P22）：与 ``onToggleFavorite`` 成对传；没有回写口就不摆这个开关。
    let isFavorite: Bool
    let onToggleFavorite: (() -> Void)?
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
    /// 正在拖控制条的进度条：拖动期间不采纳内核报回的位置，否则滑杆会被顶回去。
    /// （去掉 `private`：`PlaybackView+Controls.swift` 要用。）
    @State var isScrubbing = false
    /// 最近一次读到的播放信息：只有报得出来的内核（MPV 与自研 FFmpeg 都认这个协议）才有这一块。
    @State var playbackStats: PlaybackStats?
    /// 内核上报的轨道（系统内核现在不上报，只有 MPV 会报，见 M03P3/M03P5）。
    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    /// 当前选中的轨道（界面态；换片时回到「自动」）。
    @State private var audioSelection: TrackSelection = .auto
    @State var subtitleSelection: TrackSelection = .auto
    // 手势那一组（M03P12 起在 `PlaybackView+Gestures.swift` 里用）：**跨文件的扩展看不见 `private`**，
    // 所以这一组只能是模块内 —— 与 `PlaybackView+Overlays` / `+Stats` 那两次拆分的处理一致。
    @State var gestureBasePosition: Double?
    @State var gestureBaseVolume: Double?
    /// 左半屏亮度拖动：开始时的屏幕亮度（0...1；拿不到 = 这次拖动不做事，见 `PlatformShims.screenBrightness()`）。
    @State var gestureBaseBrightness: Double?
    /// 这次拖动在调什么：开始那一刻定，中途不换（横向拐弯也不会跳成调音量）。
    @State var gestureDrag: DragMode?
    /// 纵甩切集（M03P23）的采样器：记最近一小段 `(时刻, 纵向位移)`，松手那一刻算速度。
    /// 去掉 `private`：`PlaybackView+Gestures.swift` 要用（与手势那一组同一理由）。
    @State var gestureSwipe = PlaybackSwipeTracker()
    /// 手势提示条（进度预览 / 音量 / 亮度 / 长按倍速）；空 = 不显示。
    @State var gestureHint = ""
    /// 当前音量（0...1）：自绘内核的手势改的是它；系统内核不碰（音量交给硬件键）。
    @State var volume: Double = 1
    /// 长按临时加速的目标倍速（M03P13：可调，初值在 `start()` 里从存档读）—— 跨文件扩展要读。
    @State var longPressSpeed: Float = SpeedSetting.longPress
    /// 双指缩放的倍数（M03P14：1.0–5.0、锚点是画面中心）—— 跨文件扩展要读写，所以是模块内。
    @State var zoomScale: CGFloat = 1
    /// 捏合开始时的倍数基准（手势给的是相对量）。
    @State var gestureBaseZoom: CGFloat?
    /// 正在双指缩放：这条期间拖动（进度 / 音量 / 亮度）不做事 —— 捏合时手指也在动，别串台。
    @State var isZooming = false
    /// 长按已识别（这次触摸还没松手）：拖动不做事、点按要吞 —— **不管在不在播**
    /// （上游同款：不在播不加速，但手势照样接管）。
    @State var isSpeedBoostHolding = false
    /// 长按这次真的把速度切到长按倍速了（不在播时不切，松手也不用回）。M03P12。
    @State var isSpeedBoosting = false
    /// 长按松手的那一刻：松手补发的那次点按要吞掉（只吞一次）。
    @State var speedBoostEndedAt: Date?
    @State private var stateText = "准备中…"
    @State private var engineText = ""
    /// 出错文案（换线路失败也走它，见 `PlaybackView+Lines.swift`）—— 跨文件要用，模块内。
    @State var errorText = ""
    @State private var eventTask: Task<Void, Never>?
    @State private var resumedFromText = ""
    /// 片头 / 片尾标记（M03P16）：秒；0 = 没标。与进度写在同一份记录里（`opening` / `ending` 两列）。
    /// 去掉 `private`：`PlaybackView+OpeningEnding.swift` 要用（与手势那组同一理由）。
    @State var openingMark: Double = 0
    @State var endingMark: Double = 0
    /// 这一集已经因为片尾跳走了：别每个位置事件都再跳一次（换集时清）。
    @State var didSkipEnding = false
    /// 最近一次的位置 / 总时长：手势换算要用（M03P12），跨文件扩展看不见 `private` —— 模块内。
    @State var latestPosition: Double = 0
    @State var latestDuration: Double = 0
    /// 当前倍速（初值在 `start()` 里从存档读；范围与预设见 ``SpeedSetting``）。
    /// 长按加速松手后回到的就是它（M03P12）—— 跨文件扩展要读，所以是模块内。
    @State var speed: Float = SpeedSetting.normal
    /// 画面比例（M03P9）：**页面内偏好**（不落盘）—— 换页回到「适应」。
    /// 上游把 scale 存在 LiveSetting 里（按直播页）；我们没有「按页面分的播放设置」这套容器，
    /// 而一个全局落盘的值会把下一部片也按上一部选的比例放，所以先不做存档。
    @State private var scaleMode: PlaybackScaleMode = .fit
    @State private var isFinished = false
    /// 单集循环（M03P20，对齐上游控制条的 `repeat`）：播完（或到片尾标记）回到本集开头，不连播。
    /// 页面内偏好、不落盘 —— 与上游一样是「本次播放」的开关。
    @State var isRepeatOne = false
    /// 锁屏 / 防误触（M03P21，对齐上游 `setLock`）：锁上之后画面手势全停，控制条只剩解锁按钮。
    /// 页面内状态、不落盘；退到后台自动解锁（上游 `onUserLeaveHint` 的规矩）。
    @State var isLocked = false
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
    /// 自绘内核的控制条是否可见（M03P10）：单击画面切换，播放中几秒后自动收起。
    @State var isControlsVisible = true
    /// 「自动收起」的计时句柄：每次交互重排；切到非播放态直接取消（暂停时本来就该看得见）。
    @State var controlsHideTask: Task<Void, Never>?
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
        onToggleDanmaku: ((Bool) -> Void)? = nil,
        onEnqueueDownloads: (([DownloadRequest], String, String, [String: String]) async -> DownloadEnqueueOutcome)? = nil,
        onPlaybackStats: ((PlaybackStats) -> Void)? = nil,
        playlist: PlaybackPlaylist? = nil,
        lineSwitcher: PlaybackLineSwitcher? = nil,
        onStart: (() -> Void)? = nil,
        playbackInfoRows: [String] = [],
        isFavorite: Bool = false,
        onToggleFavorite: (() -> Void)? = nil
    ) {
        _activeResource = State(initialValue: resource)
        _activeTitle = State(initialValue: title)
        self.settings = settings
        _activeProgressContext = State(initialValue: progressContext)
        self.playlist = playlist
        _currentEpisodeIndex = State(initialValue: playlist?.currentIndex)
        self.lineSwitcher = lineSwitcher
        _selectedLine = State(initialValue: lineSwitcher?.current ?? "")
        self.progressStore = progressStore
        self.danmaku = danmaku
        self.onDanmaku = onDanmaku
        self.subtitleDisplay = subtitleDisplay
        self.subtitleCues = subtitleCues
        self.danmakuLines = danmakuLines
        self.danmakuDisplay = danmakuDisplay
        self.onToggleDanmaku = onToggleDanmaku
        self.onEnqueueDownloads = onEnqueueDownloads
        self.onPlaybackStats = onPlaybackStats
        self.onStart = onStart
        self.playbackInfoRows = playbackInfoRows
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
    }

    /// 前后台切换：锁屏的自动解锁要用（见 M03P21）。
    @Environment(\.scenePhase) private var scenePhase

    public var body: some View {
        VStack(spacing: 0) {
            playerArea
            List {
                Section("追剧与下载") {
                    if let onToggleFavorite {
                        Toggle("收藏（加入追剧）", isOn: Binding(
                            get: { isFavorite },
                            set: { _ in onToggleFavorite() }
                        ))
                    }
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
                danmakuSection
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
                lineSection
                openingEndingSection
                if activeProgressContext != nil {
                    Section("播放") {
                        Toggle("单集循环（播完回到本集开头）", isOn: $isRepeatOne)
                    }
                }
                Section("媒体") {
                    ForEach(playbackInfoRows, id: \.self) { row in
                        Text(row)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .onChange(of: scenePhase) { phase in
            // 退到后台就解锁（M03P21，上游 `onUserLeaveHint` 同款）：回来时别发现画面点不动。
            guard phase != .active else {
                return
            }
            isLocked = false
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
            // 控制条的自动收起计时也别留着（离开页面后没人需要它）。
            controlsHideTask?.cancel()
            controlsHideTask = nil
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
                    // 显隐由「单击画面」切换、播放中自动收起（M03P10）。
                    if mpvSurface != nil || ffmpegSurface != nil, isControlsVisible {
                        playerControls
                            .transition(.opacity)
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
                .animation(.easeInOut(duration: 0.2), value: isControlsVisible)
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
    /// 手势**只挂在自绘内核这边**（`interactiveLayer`，见 `PlaybackView+Gestures.swift`）：
    /// 系统内核的画面是 `VideoPlayer`，它自带一整套手势，我们再叠一层只会互相打架。
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

    /// 控制条自动收起的等待时长（M03P10）。
    static let controlsAutoHideSeconds: TimeInterval = 4

    /// 控制条该不该自动收起（**纯函数**，有单测）：只有「看得见 + 正在播」才排自动收起 ——
    /// 暂停 / 缓冲 / 结束 / 失败都留着（那时人要看它）。
    static func controlsShouldAutoHide(isVisible: Bool, state: PlayerState) -> Bool {
        isVisible && state == .playing
    }

    /// 单击画面：切换控制条，并按当前状态重排自动收起的计时。
    func toggleControlsVisibility() {
        isControlsVisible.toggle()
        scheduleControlsAutoHide()
    }

    /// 重排「自动收起」：条件不满足就把计时取消（不留一个什么都不做的任务在跑）。
    func scheduleControlsAutoHide() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        guard Self.controlsShouldAutoHide(isVisible: isControlsVisible, state: playerState) else {
            return
        }
        controlsHideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.controlsAutoHideSeconds * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            isControlsVisible = false
        }
    }

    /// 非播放态：取消自动收起并把控制条亮出来。
    func showControls() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        isControlsVisible = true
    }

    /// 播放 / 暂停（自绘控制条与「双击画面」都走它；双击那条在 `PlaybackView+Gestures.swift`）。
    func togglePlayback() async {
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
        longPressSpeed = PlaybackSpeedBook.longPressSpeed()
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
            // 画面比例也要在加载**之后**套：引擎换资源时会把显示方式复位（与倍速同一条理由）。
            await created.setScaleMode(scaleMode)
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
                // 控制条（M03P10）：播放中才排「几秒后自动收起」；其余状态亮着（暂停时人还要点它）。
                if state == .playing {
                    scheduleControlsAutoHide()
                } else {
                    showControls()
                }
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
                    switch Self.endAction(isRepeatOne: isRepeatOne, hasNextEpisode: nextEpisodeIndex != nil) {
                    case .loop:
                        // 单集循环（M03P20）：不算「看完」，也不连播 —— 直接回到开头。
                        await loopCurrentEpisode()
                    case .nextEpisode:
                        isFinished = true
                        await persist(force: true)
                        // 片尾自动下一集（M12P1）：有下一集才连播；最后一集停在结束态等人。
                        if let next = nextEpisodeIndex {
                            await switchEpisode(to: next)
                        }
                    case .stop:
                        isFinished = true
                        await persist(force: true)
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
                await skipEndingIfNeeded(current: current, duration: duration)
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
        // 片头 / 片尾标记跟着这一集的记录走：先清零，免得上一条记录（上一集）的标记漏过来。
        openingMark = 0
        endingMark = 0
        guard let activeProgressContext, let progressStore,
              let saved = await progressStore.progress(for: activeProgressContext.key)
        else {
            return activeResource
        }
        let resume = saved.resumePosition()
        openingMark = saved.opening
        endingMark = saved.ending
        // 画面比例按片记忆（M03P19，对齐上游 `History.scale`）：认不出的值回落「适应」。
        scaleMode = PlaybackScaleMode.decode(saved.scale)
        // 起播位置：片头与上次位置取靠后的那个（上游 `VodHistoryPolicy.startPositionMs`）。
        let start = PlaybackOpeningEndingRules.startPosition(opening: saved.opening, resume: resume)
        guard start > 0 else {
            return activeResource
        }
        var copy = activeResource
        copy.startPosition = start
        // 两种起播位置分开说：片头比续播位置更靠后才是「跳过片头」，否则照旧说「续播」。
        resumedFromText = saved.opening > resume
            ? "已跳过片头（\(Self.timeText(start)) 起播）"
            : "已从上次位置续播（\(Self.timeText(start))）"
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
                opening: openingMark,
                ending: endingMark,
                scale: scaleMode.rawValue,
                episodeIndex: activeProgressContext.episodeIndex,
                updatedAt: now,
                metadata: activeProgressContext.metadata
            )
        )
    }

    /// 锁上之后还允许哪些手势（**纯函数**，有单测）。
    enum LockedGesturePolicy: Equatable {
        /// 没锁：全开。
        case all
        /// 锁上：**只留单击**（把控制条叫出来 / 收起来）—— 双击、拖动、长按加速、捏合全停。
        ///
        /// 为什么留着单击：锁上时控制条只剩解锁按钮，而它跟别的控制条一样会「播放中自动收起」——
        /// 单击是把它叫回来的唯一办法（上游也是这么留的：`onSingleTap` 不看 lock）。
        case singleTapOnly
    }

    static func lockedGesturePolicy(isLocked: Bool) -> LockedGesturePolicy {
        isLocked ? .singleTapOnly : .all
    }

    /// 一集走到头（或到片尾标记）之后该干什么（**纯函数**，有单测）。
    ///
    /// 循环**优先于**连播：开了循环就是「这一集重来」，片尾标记不再把人带走
    /// （上游把循环做在内核层 —— 播完根本不到 `ended`；我们做在播放页这一层，三个内核都吃得到）。
    enum EndAction: Equatable {
        case loop
        case nextEpisode
        case stop
    }

    static func endAction(isRepeatOne: Bool, hasNextEpisode: Bool) -> EndAction {
        if isRepeatOne {
            return .loop
        }
        return hasNextEpisode ? .nextEpisode : .stop
    }

    /// 单集循环：回到本集开头接着播（不改进度记录里的「看完」，也不动选集下标）。
    func loopCurrentEpisode() async {
        // 这一集重新开始：进度条回到 0，结束态、片尾跳集的「跳过」标记、续播文案都清掉。
        latestPosition = 0
        isFinished = false
        didSkipEnding = false
        resumedFromText = ""
        guard let engine else {
            return
        }
        await engine.seek(to: 0)
        await engine.play()
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
    /// （去掉 `private`：`PlaybackView+OpeningEnding.swift` 的片尾跳集要用。）
    var nextEpisodeIndex: Int? {
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
        await applyEpisode(
            next,
            fallbackTitle: playlist.episodeName(at: index),
            episodeName: playlist.episodeName(at: index)
        )
    }

    /// 换集 / 换线路的**共同落点**（M12P1 / M03P17）：换资源 → 清界面状态 → 在**同一个引擎**上重新 load。
    ///
    /// 位置靠进度记录续上（调用方负责先把当前位置 `persist` 下去）；
    /// 弹幕按集名重新搜 —— 换集时集名变了要重搜，换线路时集名没变（就是同一集）也不会白跑。
    func applyEpisode(_ next: PlaybackEpisodeResource, fallbackTitle: String, episodeName: String) async {
        activeResource = next.resource
        activeProgressContext = next.progressContext
        activeTitle = next.title.isEmpty ? fallbackTitle : next.title
        // 新一集的界面状态：进度、轨道、提示、错误全部从零开始。
        latestPosition = 0
        latestDuration = 0
        isFinished = false
        resumedFromText = ""
        didSkipEnding = false
        errorText = ""
        audioTracks = []
        subtitleTracks = []
        audioSelection = .auto
        subtitleSelection = .auto
        isScrubbing = false
        // 字幕跟着换：内嵌的那份由新会话重新报，外挂那份要上层重新取 —— 先把旧时间轴清掉，
        // 宁可不显示，也别把上一集 / 上一条线路的字幕留在画面上（M03P18）。
        subtitleTimeline = nil
        engineSubtitleCues = []
        if let danmaku {
            onDanmaku?(DanmakuRequest(name: danmaku.name, episode: episodeName))
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
            await engine.setScaleMode(scaleMode)
        } catch let error as PlayerError {
            errorText = error.message
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 「弹幕」区（M03P18）：就地开关（写回上层的显示设置）。
    ///
    /// 只有**这一集真有弹幕**、且上层给了回写口时才出现 —— 不摆一个「这集本来就没弹幕」的假开关。
    @ViewBuilder
    private var danmakuSection: some View {
        if let onToggleDanmaku, !danmakuLines.isEmpty {
            Section("弹幕") {
                Toggle("显示弹幕", isOn: Binding(
                    get: { danmakuDisplay.isVisible },
                    set: { onToggleDanmaku($0) }
                ))
            }
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

    /// 改画面比例：先归位双指缩放，再记进界面态 + 立刻下发内核（`setScaleMode`）。
    ///
    /// 归位这条对齐上游 `onScale(tag)`：`resetScale()` 之后才 `setScale(tag)` ——
    /// 缩放是「临时看细节」，换比例就该回到 1.0（M03P14）。
    private var scaleBinding: Binding<PlaybackScaleMode> {
        Binding(
            get: { scaleMode },
            set: { mode in
                zoomScale = 1
                scaleMode = mode
                Task { await engine?.setScaleMode(mode) }
                // 按片记下来（M03P19）：下次进这一部片直接用这档。
                Task { await persist(force: true) }
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
