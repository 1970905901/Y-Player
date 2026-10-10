@testable import CatVodPlayer
import CoreVideo
import Foundation
import Testing

/// 显示渲染器（M04P8）：喂帧 / 时间轴控制 / 逐帧步进的冒烟测试。
///
/// 真正「画出来什么样」要上机看（显示层不在窗口里，单测只能验**不炸**）；
/// 这里能钉住的是：转换失败不误报、enqueue/flush/播放控制的调用语义、
/// 以及步进的「下一帧 pts」挑选（M04P23：时间轴确实挪到了那一帧上）。
@Suite("显示渲染器（M04P8）")
struct LibavVideoRendererTests {
    @Test("喂一帧不炸，播放 / 暂停 / 清队都安全")
    func rendererSmoke() throws {
        let surface = FFmpegVideoSurface()
        let renderer = LibavVideoRenderer(surface: surface)
        let pixelBuffer = try makePixelBuffer()

        let enqueued = renderer.enqueue(pixelBuffer: pixelBuffer, presentationSeconds: 0, durationSeconds: 1.0 / 30.0)
        #expect(enqueued)
        renderer.play()
        renderer.pause()
        renderer.play(rate: 1.5)
        renderer.pause()
        renderer.flush()
    }

    @Test("逐帧步进（M04P23）：时间轴停在「当前之后最近的一帧」；没有下一帧回 false，清队后也不乱走")
    func stepsOneFrameAtATime() throws {
        let renderer = LibavVideoRenderer(surface: FFmpegVideoSurface())
        let pixelBuffer = try makePixelBuffer()
        for index in 0 ..< 3 {
            _ = renderer.enqueue(
                pixelBuffer: pixelBuffer,
                presentationSeconds: Double(index) / 30,
                durationSeconds: 1.0 / 30
            )
        }
        renderer.pause()

        #expect(renderer.stepToNextFrame())
        #expect(abs(renderer.currentSeconds - 1.0 / 30) < 0.001)
        #expect(renderer.stepToNextFrame())
        #expect(abs(renderer.currentSeconds - 2.0 / 30) < 0.001)
        // 队里没有下一帧了：如实回 false（不假装走了）
        #expect(!renderer.stepToNextFrame())
        // 清队之后：台账也清了（不拿清掉的帧 pts 乱跳）
        renderer.flush()
        #expect(!renderer.stepToNextFrame())
    }

    /// 8×8 的 BGRA 帧（渲染器单测共用）。
    private func makePixelBuffer() throws -> CVPixelBuffer {
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
        return try #require(buffer)
    }
}
