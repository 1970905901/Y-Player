import AVFoundation
import CatVodCore
import Foundation

/// 系统播放内核（`AVPlayer`）。
///
/// M2 的兜底内核：保证「接口 → 首页 → 详情 → 选集 → 播放」链路可用。
/// 局限（明确记录，避免误判为“播放器坏了”）：
/// - 只支持系统可解复用/可解码的容器与编码，MKV/非常规流可能无法播放；
/// - HTTP header 通过 `AVURLAssetHTTPHeaderFieldsKey` 注入，对 **分片/密钥** 请求的覆盖有限，
///   M6 会改为「本地代理服务统一注入 header」来满足上游接入要求；
/// - 轨道切换（`selectTrack`）暂为占位，M3/M4 由自研内核实现。
public actor AVPlayerEngine: PlayerEngine {
    public nonisolated var kind: PlayerEngineKind { .system }
    public nonisolated let events: AsyncStream<PlayerEvent>

    private var continuation: AsyncStream<PlayerEvent>.Continuation?
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var monitoringTask: Task<Void, Never>?
    private var state: PlayerState = .idle
    private var lastTime: Double = 0
    private var duration: Double = 0

    public init() {
        var captured: AsyncStream<PlayerEvent>.Continuation?
        let stream = AsyncStream<PlayerEvent> { captured = $0 }
        self.events = stream
        self.continuation = captured
    }

    /// 结束事件流（由持有者在销毁内核时调用；`teardown()` 不会结束流，便于复用引擎加载下一个视频）。
    public func finishEvents() {
        continuation?.finish()
        continuation = nil
    }

    public func currentState() async -> PlayerState {
        state
    }

    // MARK: - 命令

    public func load(_ resource: MediaResource) async throws {
        guard let url = URL(string: resource.url), url.scheme != nil else {
            throw PlayerError.invalidURL(resource.url)
        }
        await teardown()
        update(.loading)

        let asset = Self.makeAsset(url: url, headers: resource.headers)
        let item = AVPlayerItem(asset: asset)
        duration = 0
        lastTime = resource.startPosition
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
        if player.rate == 0 {
            player.rate = 1
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

    private func seekAsync(to time: CMTime) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    public func setRate(_ rate: Float) async {
        player.rate = rate
        emit(.speedChanged(rate))
    }

    /// 说明：AVPlayer 的轨道选择依赖媒体选择组，M2 先记录选择不做实际切换。
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

    private func installObservers(item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            Task { await self?.handleTick(seconds) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleEnd() }
        }
    }

    private func startMonitoring() {
        monitoringTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(20)
            while !Task.isCancelled, Date() < deadline {
                guard let decision = await self?.pollStatus() else {
                    return
                }
                switch decision {
                case .ready:
                    await self?.handleReady()
                    return
                case let .failed(reason):
                    await self?.handleFailure(reason)
                    return
                case .pending:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            await self?.handleFailure("加载超时（20 秒内未就绪）")
        }
    }

    /// 就绪轮询的判定结果（避免把非 Sendable 的 `AVPlayerItem` 捕获进 `Task`）。
    private enum StatusDecision {
        case pending
        case ready
        case failed(String)
    }

    private func pollStatus() -> StatusDecision {
        guard let item = player.currentItem else {
            return .failed("播放项未建立")
        }
        switch item.status {
        case .readyToPlay:
            return .ready
        case .failed:
            return .failed(item.error?.localizedDescription ?? "未知错误")
        case .unknown:
            return .pending
        @unknown default:
            return .pending
        }
    }

    private func handleReady() {
        let seconds = player.currentItem?.duration.seconds ?? 0
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        player.play()
        update(.playing)
        emit(.timeChanged(current: lastTime, duration: duration))
    }

    private func handleFailure(_ reason: String) {
        update(.failed(reason))
        emit(.error(reason))
    }

    private func handleTick(_ seconds: Double) {
        lastTime = seconds
        if duration <= 0 {
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
        }
        emit(.timeChanged(current: seconds, duration: duration))
    }

    private func handleEnd() {
        update(.ended)
    }

    private func update(_ newState: PlayerState) {
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PlayerEvent) {
        continuation?.yield(event)
    }
}
