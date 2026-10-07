import AVKit
import CatVodCore
import CatVodPlayer
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

    @State private var engine: AVPlayerEngine?
    @State private var player: AVPlayer?
    @State private var stateText = "准备中…"
    @State private var engineText = ""
    @State private var errorText = ""
    @State private var eventTask: Task<Void, Never>?

    public init(
        resource: MediaResource,
        title: String,
        settings: PlaybackSettings = PlaybackSettings()
    ) {
        self.resource = resource
        self.title = title
        self.settings = settings
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
            Task { await current?.teardown() }
        }
    }

    private var playerArea: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
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
            try await systemEngine.load(resource)
            await systemEngine.play()
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
            case let .error(message):
                errorText = message
            case .timeChanged, .bufferedChanged, .tracksChanged, .speedChanged:
                break
            }
        }
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
