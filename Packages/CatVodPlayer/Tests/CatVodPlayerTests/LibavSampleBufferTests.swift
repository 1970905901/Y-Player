@testable import CatVodPlayer
import CoreMedia
import CoreVideo
import Foundation
import Testing

/// 帧 → 显示样本（M04P8）：纯转换，不碰显示层。
@Suite("帧 → 显示样本（M04P8）")
struct LibavSampleBufferTests {
    /// 手造一个 BGRA 的 pixel buffer（不依赖 VT 解码）。
    private func makePixelBuffer(width: Int = 320, height: Int = 240) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let code = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        return code == kCVReturnSuccess ? buffer : nil
    }

    @Test("尺寸 / 时间戳 / 时长 / ready 都带上，图像本体就是那一帧")
    func wrapsPixelBuffer() throws {
        let pixelBuffer = try #require(makePixelBuffer())
        let sample = try #require(LibavSampleBuffer.make(
            pixelBuffer: pixelBuffer,
            presentationSeconds: 1.5,
            durationSeconds: 1.0 / 30.0
        ))

        #expect(CMSampleBufferDataIsReady(sample))
        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - 1.5) < 0.0001)
        #expect(abs(CMSampleBufferGetDuration(sample).seconds - 1.0 / 30.0) < 0.0001)
        let image = try #require(CMSampleBufferGetImageBuffer(sample))
        #expect(CVPixelBufferGetWidth(image) == 320)
        #expect(CVPixelBufferGetHeight(image) == 240)
    }
}
