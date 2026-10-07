import Foundation

/// 播放内核类型。
public enum PlayerEngineKind: String, Sendable, CaseIterable {
    /// 系统播放器（`AVPlayer`）。
    ///
    /// M2 的兜底内核：在 MPVKit / 自研 FFmpeg 内核接入前保证「接口 → 详情 → 播放」链路可用。
    /// 局限：只支持系统可解的容器/编码，无法处理需要自定义解复用或解析的源。
    case system
    /// 基于 libmpv 的内核（MPVKit 提供 libmpv + FFmpeg）。
    case mpv
    /// 自研 FFmpeg 内核（VideoToolbox 硬解 + Metal 渲染 + AudioToolbox 输出 + libass 字幕）。
    case ffmpeg

    /// 展示名（设置页/播放页切换用）。
    public var displayName: String {
        switch self {
        case .system: "系统播放器"
        case .mpv: "MPV"
        case .ffmpeg: "FFmpeg（自研）"
        }
    }

    /// 该内核在当前构建中是否可用。
    ///
    /// M3 启用 MPVKit 之前 `mpv` 返回 false；M4 完成前 `ffmpeg` 返回 false；
    /// 此时 UI 与协调器会退回 `.system`。
    public var isAvailable: Bool {
        switch self {
        case .system:
            return true
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
/// 约定：
/// - 实现必须自己保证线程安全（推荐用 `actor`，UI 只从主线程调用命令方法）；
/// - 事件通过 `events` 异步序列下发，避免 UI 层轮询；
/// - `state` 用 `currentState()` 异步读取：内核多以 actor 实现，同步属性无法满足 `Sendable` 协议要求。
public protocol PlayerEngine: AnyObject, Sendable {
    var kind: PlayerEngineKind { get }
    var events: AsyncStream<PlayerEvent> { get }

    func currentState() async -> PlayerState
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

/// 播放内核选择与降级。
///
/// 规则：
/// - 按「用户偏好 → 可用性探测」选内核：偏好不可用时自动降级；
/// - 降级顺序：`preferred` → `.mpv` → `.ffmpeg` → `.system`（系统 AVPlayer 永远可用，作为最后兜底）；
/// - 结果附带原因文本，便于 UI 如实告知用户「为什么没用上 MPV」。
public struct PlayerCoordinator: Sendable {
    /// 选择结果。
    public struct Selection: Sendable, Hashable {
        public var kind: PlayerEngineKind
        /// 是否发生了降级。
        public var didFallback: Bool
        /// 偏好内核不可用时的原因（未降级时为空串）。
        public var reason: String

        public init(kind: PlayerEngineKind, didFallback: Bool, reason: String = "") {
            self.kind = kind
            self.didFallback = didFallback
            self.reason = reason
        }
    }

    /// 兜底顺序。
    public static let fallbackOrder: [PlayerEngineKind] = [.mpv, .ffmpeg, .system]

    public init() {}

    /// 选择内核。
    public func select(preferred: PlayerEngineKind) -> Selection {
        if preferred.isAvailable {
            return Selection(kind: preferred, didFallback: false)
        }
        for candidate in Self.fallbackOrder where candidate.isAvailable {
            return Selection(
                kind: candidate,
                didFallback: true,
                reason: "\(preferred.displayName) 在当前构建中不可用，已回退到 \(candidate.displayName)"
            )
        }
        // `.system` 恒可用，理论上不会走到这里。
        return Selection(kind: .system, didFallback: true, reason: "\(preferred.displayName) 不可用")
    }

    /// 按选择结果创建内核实例。
    ///
    /// M2 只有 `.system` 可创建；`.mpv`/`.ffmpeg` 实现随 M3/M4 接入，
    /// 此处返回 nil 由调用方按 `select(preferred:)` 的结果降级。
    public func makeEngine(kind: PlayerEngineKind) -> (any PlayerEngine)? {
        switch kind {
        case .system:
            return AVPlayerEngine()
        case .mpv, .ffmpeg:
            return nil
        }
    }

    /// 选择并创建内核（一步到位，自动降级）。
    public func makePreferredEngine(preferred: PlayerEngineKind) -> (engine: any PlayerEngine, selection: Selection)? {
        let selection = select(preferred: preferred)
        guard let engine = makeEngine(kind: selection.kind) else {
            return nil
        }
        return (engine, selection)
    }
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
            "播放内核 \(kind.displayName) 在当前构建中不可用"
        case let .invalidURL(url):
            "播放地址无效：\(url)"
        case let .loadFailed(reason):
            "加载失败：\(reason)"
        case let .unsupportedFeature(feature):
            "不支持的功能：\(feature)"
        }
    }
}
