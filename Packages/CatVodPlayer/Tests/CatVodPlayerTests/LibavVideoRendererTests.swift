@testable import CatVodPlayer
import CoreVideo
import Foundation
import Testing

/// 显示渲染器（M04P8）：喂帧 / 时间轴控制的冒烟测试。
///
/// 真正「画出来什么样」要上机看（显示层不在窗口里，单测只能验**不炸**）；
/// 这里能钉住的是：转换失败不误报、enqueue/flush/播放控制的调用语义。
@Suite("显示渲染器（M04P8）")
struct LibavVideoRendererTests {
    @Test("喂一帧不炸，播放 / 暂停 / 清队都安全")
    func rendererSmoke() throws {
        let surface = FFmpegVideoSurface()
        let renderer = LibavVideoRenderer(surface: surface)

        var buffer: CVPixelBuffer?
        let code = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        #expect(code == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)

        let enqueued = renderer.enqueue(pixelBuffer: pixelBuffer, presentationSeconds: 0, durationSeconds: 1.0 / 30.0)
        #expect(enqueued)
        renderer.play()
        renderer.pause()
        renderer.play(rate: 1.5)
        renderer.pause()
        renderer.flush()
    }
}
