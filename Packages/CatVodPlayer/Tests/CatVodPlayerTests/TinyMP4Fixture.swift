import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 生成一个几帧的小 MP4（测试夹具）：给输入层 / demux 类测试一个**离线的确定性输入**。
///
/// 为什么不用真网络流：单测打网络 = 红绿看运气。这个夹具用 AVAssetWriter 现场编出来，
/// M04P7 的 demux 测试可以接着用。
enum TinyMP4Fixture {
    /// 写一个 `frames` 帧（`fps` 帧率）、黑/灰交替的 H.264 MP4。
    ///
    /// 失败原因都带着走（writer.error 优先），别让调用方对着一个空文件猜。
    static func write(
        to url: URL,
        width: Int = 320,
        height: Int = 240,
        fps: Int = 30,
        frames: Int = 30
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw FixtureError.writerRejectedInput
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? FixtureError.startFailed
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0 ..< frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw FixtureError.noPixelBufferPool
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let pixelBuffer = buffer
            else {
                throw FixtureError.noPixelBuffer
            }
            fill(pixelBuffer, gray: frame % 2 == 0 ? 32 : 200)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? FixtureError.appendFailed
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? FixtureError.finishFailed
        }
    }

    /// 把整块 BGRA 填成一个灰度值（不用 CoreGraphics 画，省一层依赖）。
    private static func fill(_ pixelBuffer: CVPixelBuffer, gray: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        memset(base, Int32(gray), CVPixelBufferGetDataSize(pixelBuffer))
    }

    enum FixtureError: Error {
        case writerRejectedInput
        case startFailed
        case noPixelBufferPool
        case noPixelBuffer
        case appendFailed
        case finishFailed
    }
}
