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

    @State private var engine: AVPlayerEngine?
    @State private var player: AVPlayer?
    @State private var stateText = "准备中…"
    @State private var engineText = ""
    @State private var errorText = ""
    @State private var eventTask: Task<Void, Never>?

    public init(resource: MediaResource, title: String) {
        self.resource = resource
        self.title = title
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
        let selection = PlayerCoordinator().select(preferred: .system)
        engineText = selection.kind.displayName
        guard selection.kind == .system else {
            errorText = "当前构建仅实现系统播放内核：\(selection.reason)"
            return
        }
        guard !resource.url.isEmpty else {
            errorText = "播放地址为空"
            return
        }

        let engine = AVPlayerEngine()
        self.engine = engine
        player = await engine.systemPlayer()
        eventTask = Task { await consume(engine) }

        do {
            try await engine.load(resource)
            await engine.play()
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
