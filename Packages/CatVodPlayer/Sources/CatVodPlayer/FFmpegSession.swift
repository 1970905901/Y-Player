import Foundation

/// 自研 FFmpeg 内核（M4）的**会话 seam**。
///
/// 分层照搬 M03P3 在 MPV 上的结论，理由一模一样：
/// - 真管线（自定义 AVIO → demux → VideoToolbox / 软解 → 渲染 → 音频）要跑在自己的线程上，
///   而且只有在 Mac / 真机上才能验；
/// - 但「加载 / 播放 / 暂停 / 跳转 / 倍速 / 音量 / 轨道 / 状态 / 事件」这套**语义**
///   现在就能用假会话在 CI 上钉死（`FFmpegEngineTests`）—— 真会话落成时只动这个边界之内。
///
/// 约定：
/// - 方法都是 `async`：真会话内部有自己的线程 / 队列，调用方从外面切进去；
/// - **状态以 ``FFmpegSessionEvent`` 的 `.state` 上报为准**，但 `.loading` 例外 ——
///   引擎在 `open` 成功后自己发，会话不要重复报，免得两边打架；
/// - `Sendable` 的合规性由实现方负责（理由写在各自的实现上，同 `MpvSession`）。
public protocol FFmpegSession: AnyObject, Sendable {
    /// 打开媒体。
    ///
    /// 返回错误描述 = **立刻开不了**（地址非法、连接被拒……）；
    /// 返回 nil = 已受理，后续的播放 / 缓冲 / 失败 / 结束都走 ``events``。
    func open(_ resource: MediaResource, decoderMode: DecoderMode) async -> String?
    /// 播放（是否真的播起来看 `events` 里的状态 —— 缓冲中仍然是 `.buffering`）。
    func play() async
    func pause() async
    /// 跳转（秒）。会话自己把目标夹到合法区间。
    func seek(to seconds: Double) async
    /// 倍速。只在播放中有意义。
    func setRate(_ rate: Float) async
    /// 音量（0...1）。
    func setVolume(_ volume: Float) async
    /// 轨道选择（`.auto` / `.disabled` / `.index`，含义见 `TrackSelection`）。
    func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async
    /// 播放信息快照（M04 口径：内核报什么读什么，读不到给空值，不抛错）。
    func stats() async -> PlaybackStats
    /// 关闭并释放。**必须幂等**：引擎的 teardown 与 load 换片都可能调。
    func close() async
    /// 会话事件（状态 / 进度 / 缓冲 / 轨道）。**流结束 = 会话终结**。
    var events: AsyncStream<FFmpegSessionEvent> { get }
}

/// 会话事件：从自研管线的一堆信号里只留引擎真正要用的那几种。
public enum FFmpegSessionEvent: Sendable, Equatable {
    /// 播放状态变化（**不含 `.loading`** —— 那是引擎自己发的，见 ``FFmpegSession`` 约定）。
    case state(PlayerState)
    /// 播放进度（当前秒数 + 总时长）。
    case time(current: Double, duration: Double)
    /// 已缓冲秒数（缓冲条 / 卡顿判定用）。
    case buffered(seconds: Double)
    /// 轨道列表（demux 认全后报一次；换片 / 换轨再报）。
    case tracks(video: [Int], audio: [Int], subtitle: [Int])
}

/// 会话工厂：真会话（`LibavFFmpegSession`）从这里建。
public enum FFmpegSessionFactory {
    /// 建真会话。
    ///
    /// - Parameter surface: 画面层。**没给画面层就返回 nil** ——
    ///   宁可说「不可用」，也不给一个没有画面的播放器（同 MPV 的纪律）。
    public static func make(surface: FFmpegVideoSurface?) -> (any FFmpegSession)? {
        guard let surface else { return nil }
        return LibavFFmpegSession(surface: surface)
    }
}
