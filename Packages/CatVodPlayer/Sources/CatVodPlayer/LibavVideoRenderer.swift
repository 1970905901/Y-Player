import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 会话对渲染器的要求（seam）：真实现是 ``LibavVideoRenderer``；单测用假实现验喂帧语义。
protocol FFmpegVideoRendering: AnyObject, Sendable {
    /// 显示层还能不能吃得下（背压信号）。
    var isReadyForMoreMediaData: Bool { get }
    /// 时间轴当前秒数。
    var currentSeconds: Double { get }
    /// 送一帧；返回 false = 转换失败，这一帧被跳过。
    @discardableResult
    func enqueue(pixelBuffer: CVPixelBuffer, presentationSeconds: Double, durationSeconds: Double) -> Bool
    func play(rate: Float)
    func pause()
    /// 清掉已排队未显示的帧。
    func flush()
    /// 跳转：清显示队列，把时间轴挪到指定秒数（保持播放 / 暂停与倍速）。
    func reset(to seconds: Double, playing: Bool, rate: Float)
    /// 逐帧步进（M04P23）：把时间轴停到「当前显示位置之后、最近的那一帧」上。
    /// **不 flush、不喂帧** —— 层里排着的帧自己会顶上来。返回 false = 队里没有下一帧（停在原地）。
    func stepToNextFrame() -> Bool
}

/// 自研内核的**显示渲染器**（M04P8）：把解码帧送进 ``FFmpegVideoSurface`` 的显示层，
/// 时间轴（播放 / 暂停 / 倍速 / 当前时间）由 `AVSampleBufferRenderSynchronizer` 管。
///
/// 分工：
/// - 本类只管**喂帧与时间轴**；帧从哪来、怎么解 —— 调用方（会话）的事；
/// - 声音将来挂在**同一条** synchronizer 上（`AVSampleBufferAudioRenderer`）——
///   音画同步是结构自带的，不用手调。
///
/// 并发：`@unchecked Sendable` —— `AVSampleBufferDisplayLayer` 允许后台 enqueue / flush；
/// synchronizer 的读写由调用方串行（将来是会话的控制路径）。
final class LibavVideoRenderer: FFmpegVideoRendering, @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer
    private let synchronizer: AVSampleBufferRenderSynchronizer

    /// 排障计数（M04P13 起）：进层多少帧、样本转换失败多少次、显示层 failed 过多少次。
    /// **只在解码线程里读写**（日志也从那条线上打）。
    private(set) var enqueuedCount = 0
    private(set) var conversionFailureCount = 0
    private(set) var failedStatusCount = 0

    /// 已喂进层、还没被 flush 的帧 pts（M04P23）：`AVSampleBufferDisplayLayer` 的队列读不回来，
    /// 而「当前之后最近那一帧的 pts」是逐帧步进唯一的输入 —— 自己记一份就够（过期的步进时随手清）。
    /// 并发：`enqueue` 在解码线程追加、`stepToNextFrame` 在控制线程读 —— 用锁串。
    private var queuedSeconds: [Double] = []
    private let queueLock = NSLock()

    /// 生产入口：跟音频共用**一条** synchronizer（音画同步的结构基础）。
    init(surface: FFmpegVideoSurface, synchronizer: AVSampleBufferRenderSynchronizer) {
        layer = surface.layer
        self.synchronizer = synchronizer
        synchronizer.addRenderer(layer)
    }

    /// 自己单独用（只有画面的场景 / 单测）：自开一条时间轴。
    convenience init(surface: FFmpegVideoSurface) {
        self.init(surface: surface, synchronizer: AVSampleBufferRenderSynchronizer())
    }

    /// 显示层还能不能吃得下 —— 吃不下就先别解（给会话的**背压**信号）。
    var isReadyForMoreMediaData: Bool {
        layer.isReadyForMoreMediaData
    }

    /// 送一帧。转换失败（底层创建不出样本）就跳过这一帧，不炸链路。
    @discardableResult
    func enqueue(pixelBuffer: CVPixelBuffer, presentationSeconds: Double, durationSeconds: Double) -> Bool {
        guard let sample = LibavSampleBuffer.make(
            pixelBuffer: pixelBuffer,
            presentationSeconds: presentationSeconds,
            durationSeconds: durationSeconds
        ) else {
            conversionFailureCount += 1
            if conversionFailureCount <= 3 {
                let size = "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
                let failure = "帧转样本失败（第 \(conversionFailureCount) 次）：\(size)"
                LibavTrace.logger.error("\(failure, privacy: .public)")
            }
            return false
        }
        // 层一旦 failed / 要求 flush，再喂多少都是白喂 —— 这是「有声音没画面」最常见的根：
        // 先 flush（Apple 的规矩）再喂，并把它打出来，别让证据烂在内存里。
        if layer.status == .failed {
            failedStatusCount += 1
            // 同理：插值里别引用属性（escaping autoclosure 要显式 self），先落成局部再打。
            let detail = layer.error.map { String(describing: $0) } ?? "无详情"
            LibavTrace.logger.error("显示层 failed：\(detail, privacy: .public)；flush 后继续")
            layer.flush()
        }
        if layer.requiresFlushToResumeDecoding {
            LibavTrace.logger.notice("显示层要求 flush（被中断过）；先 flush 再喂")
            layer.flush()
        }
        layer.enqueue(sample)
        enqueuedCount += 1
        queueLock.lock()
        queuedSeconds.append(presentationSeconds)
        queueLock.unlock()
        // 首帧必打；之后每 120 帧打一次，够看出「在进帧但层不渲染」这类怪事。
        if enqueuedCount == 1 || enqueuedCount % 120 == 0 {
            let enqueued = "第 \(enqueuedCount) 帧入层：pts=\(presentationSeconds)s "
                + "层状态=\(layer.status.rawValue) 可喂=\(layer.isReadyForMoreMediaData) "
                + "时间轴=\(currentSeconds)s"
            LibavTrace.logger.notice("\(enqueued, privacy: .public)")
        }
        return true
    }

    /// 时间轴当前秒数（正在显示 / 已排到的位置）。
    var currentSeconds: Double {
        synchronizer.currentTime().seconds
    }

    /// 开始 / 继续；`rate` 就是倍速（1 = 正常）。
    func play(rate: Float = 1) {
        synchronizer.setRate(rate, time: synchronizer.currentTime())
    }

    /// 暂停（时间轴停在原地）。
    func pause() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    /// 清掉已排队未显示的帧（跳转 / 重开时用）。
    func flush() {
        layer.flush()
        queueLock.lock()
        queuedSeconds.removeAll()
        queueLock.unlock()
    }

    func reset(to seconds: Double, playing: Bool, rate: Float) {
        flush()
        synchronizer.setRate(
            playing ? rate : 0,
            time: CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        )
    }

    /// 逐帧步进（M04P23）：把时间轴停到「比当前显示位置晚、最近的那一帧」上。
    ///
    /// - 不 flush 也不喂帧：层里排着的那批帧就是队列，时间轴挪过去，显示层自然把那一帧顶上来
    ///   （往前挪一帧的时间，显示的是**下一帧**，不是重新解一帧 —— 解码线程本来就一直解在前头）；
    /// - 顺手清掉「当前之前 1 秒外」的过期 pts：长片一直播、台账里堆着几十万条也不怕；
    /// - 迟到帧被层自己丢掉的那些算不进来（我们只记喂过的）—— 最多是那一格偏差，不会乱跳。
    func stepToNextFrame() -> Bool {
        let current = currentSeconds
        queueLock.lock()
        queuedSeconds.removeAll { $0 < current - 1 }
        let next = queuedSeconds.lazy.filter { $0 > current + 0.001 }.min()
        queueLock.unlock()
        guard let next else { return false }
        synchronizer.setRate(0, time: CMTime(seconds: next, preferredTimescale: 1_000_000))
        return true
    }
}
