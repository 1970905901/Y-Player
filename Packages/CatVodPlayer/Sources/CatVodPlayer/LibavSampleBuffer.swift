import CoreMedia
import CoreVideo
import Foundation

/// 自研内核的**帧 → 显示样本**转换（M04P8）：`CVPixelBuffer` → `CMSampleBuffer`。
///
/// 显示层（`AVSampleBufferDisplayLayer`）只吃 `CMSampleBuffer`；VT 解出来的帧是 `CVPixelBuffer`，
/// 中间这一层就干这一件事。
///
/// 为什么是纯函数类型：转换不碰层、不碰时钟 —— 单测拿一个手造的 pixel buffer
/// 就能验尺寸 / 时间戳 / 时长；显示那段（presentation）归 ``LibavVideoRenderer``。
enum LibavSampleBuffer {
    /// 包一帧。返回 nil = 底层创建失败（极端情况，调用方跳过这一帧即可）。
    ///
    /// 颜色信息（HDR 的 EDR 全靠它）由 `CMVideoFormatDescriptionCreateForImageBuffer`
    /// 从 pixel buffer 的附件里带出来 —— VT 解出来的帧带不带这些附件，上机用
    /// M04P2 的「色彩 / 输出」两行验。
    ///
    /// 时间用**微秒时基**（1_000_000）：每帧的 pts 是绝对时间，微秒截断不累积漂移；
    /// 600 那种「常用小刻度」对 23.976fps 这类帧率是除不尽的。
    static func make(
        pixelBuffer: CVPixelBuffer,
        presentationSeconds: Double,
        durationSeconds: Double
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatCode = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatCode == noErr, let formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 1_000_000),
            presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleCode = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleCode == noErr, let sampleBuffer else {
            return nil
        }
        return sampleBuffer
    }
}
