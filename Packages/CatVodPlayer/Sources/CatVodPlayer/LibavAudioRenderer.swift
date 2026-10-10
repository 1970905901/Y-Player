import AVFoundation
import CoreMedia
import Foundation

/// 会话对音频渲染器的要求（seam）：真实现是 ``LibavAudioRenderer``；单测用假实现。
///
/// 时间轴不在这里 —— 音频与视频挂在**同一条** `AVSampleBufferRenderSynchronizer` 上
/// （由画面侧的渲染器驱动播放 / 暂停 / 倍速），音画同步是结构自带的。
protocol FFmpegAudioRendering: AnyObject, Sendable {
    /// 渲染器还能不能吃得下（背压信号）。
    var isReadyForMoreMediaData: Bool { get }
    /// 送一块音频样本。
    func enqueue(_ sample: CMSampleBuffer)
    /// 清掉已排队未播的样本（跳转 / 重开时用）。
    func flush()
    /// 音量（0...1）。
    func setVolume(_ volume: Float)
}

/// 自研内核的**音频渲染器**（M04P10）：`AVSampleBufferAudioRenderer` 的薄壳。
///
/// 它自己不掌握时间轴：初始化时挂到会话给的 synchronizer 上，
/// 与 ``FFmpegVideoSurface`` 的显示层共用同一只时钟。
///
/// 并发：`@unchecked Sendable` —— enqueue / flush 允许后台调用；
/// 音量由控制路径写（调用方串行）。
final class LibavAudioRenderer: FFmpegAudioRendering, @unchecked Sendable {
    private let renderer = AVSampleBufferAudioRenderer()

    init(synchronizer: AVSampleBufferRenderSynchronizer) {
        synchronizer.addRenderer(renderer)
    }

    var isReadyForMoreMediaData: Bool {
        renderer.isReadyForMoreMediaData
    }

    func enqueue(_ sample: CMSampleBuffer) {
        renderer.enqueue(sample)
    }

    func flush() {
        renderer.flush()
    }

    func setVolume(_ volume: Float) {
        renderer.volume = min(max(volume, 0), 1)
    }
}
