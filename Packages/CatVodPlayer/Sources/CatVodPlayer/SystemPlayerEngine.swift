import AVFoundation
import CatVodCore
import Foundation

/// 系统播放内核（`AVPlayer`）。
///
/// 并发说明（重要）：iOS 18 / macOS 15 SDK 起 `AVPlayer` 标注为 `@MainActor`，
/// 因此本内核实现为 `@MainActor` 类（而不是 `actor`）——这既符合 SDK 约束，
/// 也符合 AVFoundation 本身的线程模型。`kind` / `events` 为 `nonisolated`，满足 `PlayerEngine` 协议。
///
/// 职责范围（M2）：保证「接口 → 首页 → 详情 → 选集 → 播放」链路可用。
/// 局限（明确记录，避免误判为“播放器坏了”）：
/// - 只支持系统可解复用/可解码的容器与编码；
/// - HTTP header 通过 `AVURLAssetHTTPHeaderFieldsKey` 注入，对分片/密钥请求覆盖有限，M6 改为本地代理统一注入；
/// - **不提供强制硬解/软解开关**：`decoderMode` 仅被记录，实际由系统决定（UI 需如实说明）。
@MainActor
public final class AVPlayerEngine: PlayerEngine {
    nonisolated public let kind: PlayerEngineKind = .system
    nonisolated public let events: AsyncStream<PlayerEvent>
    /// 用户选择的解码方式（系统内核不支持强制切换，仅记录以便设置页如实展示）。
    nonisolated public let decoderMode: DecoderMode

    // 说明：以下存储属性为模块内可见（非 private），因为就绪轮询与事件观测放在
    // `SystemPlayerEngine+Monitoring.swift`（`private` 是文件作用域，跨文件无法访问）。
    var continuation: AsyncStream<PlayerEvent>.Continuation?
    let player = AVPlayer()
    /// 用户请求的倍速。
    ///
    /// 为什么必须记着它：`AVPlayer.play()` 等价于「rate 置 1」，于是「设了 1.5x → 暂停 → 继续」
    /// 会悄悄退回正常速度（M02P15 修的就是这个）。`play()` 现在按这里记的值恢复。
    var requestedRate: Float = SpeedSetting.normal
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var monitoringTask: Task<Void, Never>?
    var state: PlayerState = .idle
    var lastTime: Double = 0
    var duration: Double = 0

    public init(decoderMode: DecoderMode = .hardware) {
        self.decoderMode = decoderMode
        var captured: AsyncStream<PlayerEvent>.Continuation?
        let stream = AsyncStream<PlayerEvent> { captured = $0 }
        events = stream
        continuation = captured
    }

    public func currentState() async -> PlayerState {
        state
    }

    /// 供系统播放器 UI（`AVKit.VideoPlayer`）绑定的 `AVPlayer` 实例。
    public func systemPlayer() -> AVPlayer {
        player
    }

    /// 结束事件流（由持有者在销毁内核时调用；`teardown()` 不会结束流，便于复用引擎加载下一个视频）。
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
        update(.loading)

        let item = AVPlayerItem(asset: Self.makeAsset(url: url, headers: resource.headers))
        duration = 0
        // 每条资源从正常速度起播：倍速是「本次播放的偏好」，由上层加载后自己套用（播放页从存档读）。
        requestedRate = SpeedSetting.normal
        lastTime = max(resource.startPosition, 0)
        player.replaceCurrentItem(with: item)
        installObservers(item: item)

        if resource.startPosition > 0 {
            // 用 completion-handler 版本（经 seekAsync 包装）：
            // 直接写 player.seek(to:) 会被解析成 async 重载，行为与完成回调不一致。
            await seekAsync(to: CMTime(seconds: resource.startPosition, preferredTimescale: 600))
        }
        startMonitoring()
    }

    public func play() async {
        player.play()
        // `AVPlayer.play()` 等价于把 rate 置 1：把记着的倍速找回来，否则「设 1.5x → 暂停 → 继续」会退回 1.0x。
        if player.rate != requestedRate {
            player.rate = requestedRate
        }
        update(.playing)
    }

    public func pause() async {
        player.pause()
        update(.paused)
    }

    public func seek(to seconds: Double) async {
        let target = max(seconds, 0)
        await seekAsync(to: CMTime(seconds: target, preferredTimescale: 600))
        lastTime = target
        emit(.timeChanged(current: target, duration: duration))
    }

    /// 设倍速。
    ///
    /// 注意 AVFoundation 的语义：`rate != 0` 就等于「在播」——暂停状态下设倍速会**开始播放**
    /// （与上游 ExoPlayer 的 `setSpeed` 同类）。播放页只在用户操作时调用，所以不额外拦。
    public func setRate(_ rate: Float) async {
        requestedRate = rate
        player.rate = rate
        emit(.speedChanged(rate))
    }

    /// 音量（0...1）：写 `AVPlayer.volume` —— 这是 App 内的相对音量，系统音量仍归硬件键。
    public func setVolume(_ volume: Float) async {
        player.volume = min(max(volume, 0), 1)
    }

    /// 说明：AVPlayer 的轨道选择依赖媒体选择组，M2 先记录选择不做实际切换（M3/M4 由自研内核实现）。
    public func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        _ = selection
        _ = kind
    }

    public func teardown() async {
        monitoringTask?.cancel()
        monitoringTask = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - 内部

    /// 按站点 header 构造 asset；无 header 时走系统默认缓存/网络行为。
    static func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        guard !headers.isEmpty else {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    func seekAsync(to time: CMTime) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    func update(_ newState: PlayerState) {
        state = newState
        emit(.stateChanged(newState))
    }

    func emit(_ event: PlayerEvent) {
        continuation?.yield(event)
    }
}
