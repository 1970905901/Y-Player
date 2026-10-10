@testable import CatVodPlayer
import CoreVideo
import Foundation
import Testing

/// 自研内核的视频解码层（M04P7）：VideoToolbox 硬解 → CVPixelBuffer。
///
/// 输入用 ``TinyMP4Fixture`` 现场编的小文件；不打网络。
@Suite("Libav 视频解码（M04P7）")
struct LibavVideoDecoderTests {
    @Test("没打开的输入：明确报错")
    func openWithoutInput() {
        let decoder = LibavVideoDecoder()
        let failure = decoder.open(input: LibavInput())
        #expect(failure != nil)
    }

    @Test("时间戳换算：pts × 时基；无效 pts 给 0")
    func timestampMath() {
        // 1/15360 时基（mp4 常见）、30fps：每帧 512 → 第 2 帧 = 1024/15360 = 1/15 秒
        let timeBase = AVRational(num: 1, den: 15360)
        #expect(LibavVideoDecoder.seconds(pts: 0, timeBase: timeBase) == 0)
        #expect(abs(LibavVideoDecoder.seconds(pts: 1024, timeBase: timeBase) - 1.0 / 15.0) < 0.0001)
        #expect(LibavVideoDecoder.seconds(pts: Int64.min, timeBase: timeBase) == 0)
        #expect(LibavVideoDecoder.seconds(pts: 100, timeBase: AVRational(num: 1, den: 0)) == 0)
    }

    @Test("VideoToolbox 硬解：前 5 帧 CVPixelBuffer，尺寸与时间戳对得上")
    func decodeFirstFrames() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libavdecode-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30)

        let input = LibavInput()
        defer { input.close() }
        let inputFailure = input.open(url: url.path, headers: [:])
        #expect(inputFailure == nil)

        let decoder = LibavVideoDecoder()
        defer { decoder.close() }
        let openFailure = decoder.open(input: input)
        #expect(openFailure == nil)

        let frames = decoder.decodeFrames(5)
        #expect(frames.count == 5)
        let first = try #require(frames.first)
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == 320)
        #expect(CVPixelBufferGetHeight(first.pixelBuffer) == 240)
        #expect(abs(first.seconds) < 0.001)
        let second = try #require(frames.dropFirst().first)
        #expect(abs(second.seconds - 1.0 / 30.0) < 0.002)
        // 逐帧单调（B 帧重排后也是按显示顺序吐出来的）
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(previous.seconds <= next.seconds)
        }
    }
}
