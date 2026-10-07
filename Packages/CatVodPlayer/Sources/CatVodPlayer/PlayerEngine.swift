import Foundation

/// 播放内核类型。
public enum PlayerEngineKind: String, Sendable, CaseIterable {
    /// 基于 libmpv 的内核（MPVKit 提供 libmpv + FFmpeg）。
    case mpv
    /// 自研 FFmpeg 内核（VideoToolbox 硬解 + Metal 渲染 + AudioToolbox 输出 + libass 字幕）。
    case ffmpeg

    /// 该内核在当前构建中是否可用。
    ///
    /// M3 启用 MPVKit 之前，`mpv` 返回 false，UI 会回退到 `ffmpeg`（M4 完成前两者都不可用时回退到系统 AVPlayer）。
    public var isAvailable: Bool {
        switch self {
        case .mpv:
            #if canImport(Libmpv)
            return true
            #else
            return false
            #endif
        case .ffmpeg:
            #if canImport(Libavformat)
            return true
            #else
            return false
            #endif
        }
    }
}

/// 播放状态。
public enum PlayerState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case ended
    case failed(String)

    public var isPlaying: Bool {
        self == .playing
    }
}

/// 播放器事件（通过 `AsyncStream` 输出给 UI）。
public enum PlayerEvent: Sendable, Equatable {
    case stateChanged(PlayerState)
    case timeChanged(current: Double, duration: Double)
    case bufferedChanged(seconds: Double)
    case tracksChanged(video: [Int], audio: [Int], subtitle: [Int])
    case speedChanged(Float)
    case error(String)
}

/// 轨道选择。
public enum TrackSelection: Sendable, Hashable {
    case auto
    case disabled
    case index(Int)
}

/// 媒体资源：把站点/解析产出的播放信息归一化成内核输入。
///
/// `header` 必须覆盖主清单、子清单、分片、密钥与字幕请求
/// （webhtv `docs/integration/player.md` 接入要求第 3 条）。
public struct MediaResource: Sendable, Hashable {
    public var url: String
    public var headers: [String: String]
    /// 起播位置（秒）。
    public var startPosition: Double
    /// 外部字幕地址。
    public var subtitleURLs: [String]
    /// 媒体 MIME（来自 `Result.format`）。
    public var format: String
    /// 标题/封面，供系统控制中心与投屏使用。
    public var title: String
    public var artwork: String

    public init(
        url: String,
        headers: [String: String] = [:],
        startPosition: Double = 0,
        subtitleURLs: [String] = [],
        format: String = "",
        title: String = "",
        artwork: String = ""
    ) {
        self.url = url
        self.headers = headers
        self.startPosition = startPosition
        self.subtitleURLs = subtitleURLs
        self.format = format
        self.title = title
        self.artwork = artwork
    }
}

/// 播放内核统一接口。
///
/// 约定：实现必须自己保证线程安全（UI 只从主线程调用命令方法）；
/// 事件通过 `events` 异步序列下发，避免 UI 层轮询。
public protocol PlayerEngine: AnyObject, Sendable {
    var kind: PlayerEngineKind { get }
    var events: AsyncStream<PlayerEvent> { get }
    var state: PlayerState { get }

    func load(_ resource: MediaResource) async throws
    func play() async
    func pause() async
    func seek(to seconds: Double) async
    func setRate(_ rate: Float) async
    func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async
    func teardown() async
}

/// 轨道类别。
public enum TrackKind: String, Sendable, CaseIterable {
    case video
    case audio
    case subtitle
}

/// 播放错误。
public enum PlayerError: Error, Sendable, Equatable {
    case engineUnavailable(PlayerEngineKind)
    case invalidURL(String)
    case loadFailed(String)
    case unsupportedFeature(String)

    public var message: String {
        switch self {
        case let .engineUnavailable(kind):
            "播放内核 \(kind.rawValue) 在当前构建中不可用"
        case let .invalidURL(url):
            "播放地址无效：\(url)"
        case let .loadFailed(reason):
            "加载失败：\(reason)"
        case let .unsupportedFeature(feature):
            "不支持的功能：\(feature)"
        }
    }
}
