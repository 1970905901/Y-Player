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

    /// 进度落库节流间隔（秒）：播放中不必每秒写一次。
    static let persistInterval: TimeInterval = 5

    public init(
        resource: MediaResource,
        title: String,
        settings: PlaybackSettings = PlaybackSettings(),
        progressContext: PlaybackProgressContext? = nil,
        progressStore: PlaybackProgressStore? = nil
    ) {
        self.resource = resource
        self.title = title
        self.settings = settings
        self.progressContext = progressContext
        self.progressStore = progressStore
    }

    public var body: some View {
        VStack(spacing: 0) {
            playerArea
            List {
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
        }
        .navigationTitle(title)
        .task { await start() }
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
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
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
                await persist(force: false)
            case .bufferedChanged, .tracksChanged, .speedChanged:
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
