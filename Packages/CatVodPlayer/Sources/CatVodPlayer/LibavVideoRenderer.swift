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
            return false
        }
        layer.enqueue(sample)
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
    }

    func reset(to seconds: Double, playing: Bool, rate: Float) {
        layer.flush()
        synchronizer.setRate(
            playing ? rate : 0,
            time: CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        )
    }
}
