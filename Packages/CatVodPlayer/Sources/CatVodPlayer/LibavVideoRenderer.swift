import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

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
final class LibavVideoRenderer: @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer
    private let synchronizer: AVSampleBufferRenderSynchronizer

    init(surface: FFmpegVideoSurface) {
        layer = surface.layer
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(layer)
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
}
