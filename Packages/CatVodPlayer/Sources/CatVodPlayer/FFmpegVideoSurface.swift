import AVFoundation

/// 自研 FFmpeg 内核的画面目标：一层 `AVSampleBufferDisplayLayer`（M04P5 记录的首选渲染路径）。
///
/// 为什么是它（而不是自绘 Metal）：
/// - demux / 解码我们自己做，**presentation**（HDR/EDR 输出、帧调度、A/V 同步、倍速）
///   交给系统渲染管线；
/// - 它与将来的音频侧（`AVSampleBufferAudioRenderer`）共用一个
///   `AVSampleBufferRenderSynchronizer` 时钟 —— 音画同步是结构上自带的，不是后期调的。
///
/// 与 ``MpvVideoSurface`` 同一套路：
/// - 引擎与界面**都要持有它**（渲染器往层里送样本、界面把层挂进视图层级），
///   生命周期必须比会话长；
/// - `CatVodPlayer` 不 import UIKit/AppKit —— 两端的宿主视图在 `CatVodUI/Platform` 里。
///
/// `@unchecked Sendable`：层的创建与布局在主线程（界面层保证），渲染侧只对它 enqueue/flush。
public final class FFmpegVideoSurface: @unchecked Sendable {
    /// 画面层。界面层负责挂进视图层级；``LibavVideoRenderer`` 负责往里送样本。
    public let layer = AVSampleBufferDisplayLayer()

    public init() { }

    /// 画面比例（M03P9）：只有 `videoGravity` 三态。16:9 / 4:3 映射不出来（``avVideoGravity`` 是 nil）——
    /// 那两档这里**什么都不做**：静默改成「适应」才是说谎；界面本来也不会对自研内核列它们
    /// （见 `PlaybackScaleMode.supportedModes(by:)`）。
    public func setScaleMode(_ mode: PlaybackScaleMode) {
        guard let gravity = mode.avVideoGravity else {
            return
        }
        layer.videoGravity = gravity
    }
}

extension PlaybackScaleMode {
    /// `AVSampleBufferDisplayLayer.videoGravity` 对应值；`nil` = 这一档 gravity 表达不了。
    var avVideoGravity: AVLayerVideoGravity? {
        switch self {
        case .fit: .resizeAspect
        case .crop: .resizeAspectFill
        case .stretch: .resize
        case .ratio16x9, .ratio4x3: nil
        }
    }
}
