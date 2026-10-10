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

    /// 该内核在当前构建中是否**可用**。
    ///
    /// 语义（刻意收紧，M03P1 接入 MPVKit 时修正）：
    /// **「能用」= 引擎已实装 + 依赖可用**，而不是「依赖链接上了」。
    /// 之前这里直接看 `canImport(Libmpv)`，一旦 MPVKit 接进来就会立刻返回 true，
    /// 而 `MpvEngine` 还没实装 —— 界面会宣称 MPV 可用却根本播不了。
    /// 依赖侧的事实现在只由 ``MpvAvailability``（libmpv）与 ``FFmpegAvailability``（Libav*）暴露，两者不混用。
    ///
    /// MPV 另有一条：引擎实装后**还要**等渲染路径就绪（没有画面 = 不能用），
    /// 所以 `.mpv` 要 `isEngineImplemented && isVideoOutputReady` 两个都真。
    /// 自研 FFmpeg（M04P13 接进创建路径）要 `isEngineImplemented && isComplete`：
    /// 引擎实装 + Libav 六件套真能 import、真能链接（「链接上了」不算数，能播才算）。
    ///
    /// **策略（M02P3）**：不可用时由 UI 明确提示并引导用户改设置，**不自动退回 `.system`**。
    public var isAvailable: Bool {
        switch self {
        case .system:
            return true
        case .mpv:
            return MpvAvailability.isEngineImplemented && MpvAvailability.isVideoOutputReady
        case .ffmpeg:
            return FFmpegAvailability.isEngineImplemented && FFmpegAvailability.isComplete
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
/// - 实现必须自己保证线程安全：与 AVFoundation 强绑定的内核用 `@MainActor` 类
///   （iOS 18 起 `AVPlayer` 受主线程约束），纯 C-API 内核用 `actor`；
/// - 事件通过 `events` 异步序列下发，避免 UI 层轮询；
/// - `state` 用 `currentState()` 异步读取：内核多以 actor/全局 Actor 实现，同步属性无法满足 `Sendable` 要求。
/// - **内核选择由用户在设置里手动指定，运行时不自动降级**（见 ``PlayerCoordinator``）。
public protocol PlayerEngine: AnyObject, Sendable {
    var kind: PlayerEngineKind { get }
    var events: AsyncStream<PlayerEvent> { get }

    func currentState() async -> PlayerState
    func load(_ resource: MediaResource) async throws
    func play() async
    func pause() async
    func seek(to seconds: Double) async
    func setRate(_ rate: Float) async
    /// 音量（0...1）。系统内核写 `AVPlayer.volume`；MPV 写 `volume`（0–100，100 = 原声）。
    func setVolume(_ volume: Float) async
    func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async
    func teardown() async
}

/// 轨道类别。
public enum TrackKind: String, Sendable, CaseIterable {
    case video
    case audio
    case subtitle
}

/// 解码方式（硬解 / 软解）。
///
/// 由用户在设置页**手动选择**，不允许运行时偷偷切换（见 ``PlaybackSettings``）。
public enum DecoderMode: String, Sendable, CaseIterable {
    /// 硬件解码（VideoToolbox / 内核自带硬解）。
    case hardware
    /// 软件解码。
    case software

    public var displayName: String {
        switch self {
        case .hardware: "硬件解码"
        case .software: "软件解码"
        }
    }

    /// 该解码方式对指定内核是否有效。
    ///
    /// 说明：系统播放器（`AVPlayer`）不提供“强制软解/硬解”的开关，由系统自行决定；
    /// 因此对 `.system` 该设置无效，UI 必须如实标注而不是假装生效。
    public func isSupported(by engine: PlayerEngineKind) -> Bool {
        switch engine {
        case .system: false
        case .mpv, .ffmpeg: true
        }
    }
}

/// 播放设置：内核与解码方式**均由用户手动选择**。
public struct PlaybackSettings: Sendable, Hashable {
    public var engine: PlayerEngineKind
    public var decoderMode: DecoderMode

    public init(engine: PlayerEngineKind = .system, decoderMode: DecoderMode = .hardware) {
        self.engine = engine
        self.decoderMode = decoderMode
    }

    /// 所选解码方式在当前内核是否有效（无效时 UI 需要提示）。
    public var isDecoderModeEffective: Bool {
        decoderMode.isSupported(by: engine)
    }
}

/// 播放内核解析结果。
///
/// **策略：严格按用户设置执行，不做自动降级。**
/// 用户选了不可用的内核时，返回 `.unavailable` 并由 UI 明确提示，
/// 而不是静默切换到别的内核（避免“设置不生效”与画质/兼容性意外变化）。
public enum PlayerEngineResolution: Sendable, Hashable {
    /// 可用：按用户选择的内核播放。
    case ready(PlayerEngineKind)
    /// 不可用：给出原因，交由用户修改设置。
    case unavailable(kind: PlayerEngineKind, reason: String)
}

/// 播放内核解析与创建。
///
/// 标注 `@MainActor`：创建系统内核（`AVPlayerEngine` 是 `@MainActor` 类，
/// 因为 iOS 18 起 `AVPlayer` 本身受主线程约束）必须发生在主线程；
/// 解析结果 `PlayerEngineResolution` 仍是普通值类型，可自由传递。
@MainActor
public struct PlayerCoordinator {
    public init() { }

    /// 按用户设置解析内核（**不降级**）。
    public func resolve(settings: PlaybackSettings) -> PlayerEngineResolution {
        guard settings.engine.isAvailable else {
            return .unavailable(kind: settings.engine, reason: Self.unavailableReason(for: settings.engine))
        }
        return .ready(settings.engine)
    }

    /// 创建内核实例；**没给画面层的自绘内核返回 nil**（`.system` 不需要画面层）。
    ///
    /// 这不是降级：调用方必须把 nil 视为“该内核不可用”并提示用户，不得改用其它内核。
    ///
    /// 两个自绘内核都要画面层，但形状不同：
    /// - MPV 要 `videoSurface`（M03P1 第 3 步的渲染路径：MoltenVK 画进 `CAMetalLayer`）；
    /// - 自研 FFmpeg 要 `ffmpegSurface`（M04P5 定的路径：`AVSampleBufferDisplayLayer`）。
    /// 宁可说「不可用」，也不给一个没有画面的播放器。
    public func makeEngine(
        kind: PlayerEngineKind,
        decoderMode: DecoderMode,
        videoSurface: MpvVideoSurface? = nil,
        ffmpegSurface: FFmpegVideoSurface? = nil
    ) -> (any PlayerEngine)? {
        switch kind {
        case .system:
            return AVPlayerEngine(decoderMode: decoderMode)
        case .mpv:
            guard let videoSurface else {
                return nil
            }
            return MpvEngine(decoderMode: decoderMode, videoSurface: videoSurface)
        case .ffmpeg:
            guard let ffmpegSurface else {
                return nil
            }
            return FFmpegEngine(decoderMode: decoderMode, videoSurface: ffmpegSurface)
        }
    }

    /// 不可用原因（UI 直接展示）。
    public static func unavailableReason(for kind: PlayerEngineKind) -> String {
        switch kind {
        case .system:
            return "系统播放器不可用（异常状态，请反馈）"
        case .mpv:
            return "MPV 内核不可用：libmpv 依赖缺失，或建引擎时没有给它画面层（渲染路径见 M03P1 第 3 步）"
        case .ffmpeg:
            // 依赖事实由 `FFmpegAvailability` 提供（M04P4 起），这里只说人话，不再重复探测。
            guard FFmpegAvailability.isComplete else {
                let missing = FFmpegAvailability.missingNames.joined(separator: "、")
                return "自研 FFmpeg 内核依赖不全：缺 \(missing)"
            }
            return "自研 FFmpeg 内核当前不可用：建引擎时没有给它画面层"
        }
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
