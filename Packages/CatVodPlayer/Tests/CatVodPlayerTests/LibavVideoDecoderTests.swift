@testable import CatVodPlayer
import CoreMedia
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
        let failure = decoder.open(input: LibavInput(), decoderMode: .hardware)
        #expect(failure != nil)
    }

    @Test("时间戳换算：pts × 时基；无效 pts 给 0")
    func timestampMath() {
        // 1/15360 时基（mp4 常见）、30fps：每帧 512 → 第 2 帧 = 1024/15360 = 1/15 秒
        #expect(LibavVideoDecoder.seconds(pts: 0, timeBaseNumerator: 1, timeBaseDenominator: 15360) == 0)
        #expect(
            abs(LibavVideoDecoder.seconds(pts: 1024, timeBaseNumerator: 1, timeBaseDenominator: 15360) - 1.0 / 15.0)
                < 0.0001
        )
        #expect(LibavVideoDecoder.seconds(pts: Int64.min, timeBaseNumerator: 1, timeBaseDenominator: 15360) == 0)
        #expect(LibavVideoDecoder.seconds(pts: 100, timeBaseNumerator: 1, timeBaseDenominator: 0) == 0)
    }

    @Test("fourCC：像素格式的日志写法（高位在前；不可打印退回十六进制）")
    func fourCCFormatting() {
        #expect(LibavVideoDecoder.fourCC(0x3432_3076) == "420v")
        #expect(LibavVideoDecoder.fourCC(0x7834_3230) == "x420")
        #expect(LibavVideoDecoder.fourCC(0x4247_5241) == "BGRA")
        #expect(LibavVideoDecoder.fourCC(0) == "0x0")
    }

    @Test("编码名 → CoreMedia 类型：只认能确证的两种，认不出给 nil")
    func videoToolboxCodecTypeMapping() {
        #expect(LibavVideoDecoder.videoToolboxCodecType(codecName: "h264") == kCMVideoCodecType_H264)
        #expect(LibavVideoDecoder.videoToolboxCodecType(codecName: "HEVC") == kCMVideoCodecType_HEVC)
        #expect(LibavVideoDecoder.videoToolboxCodecType(codecName: "av1") == nil)
    }

    @Test("软解：sws 把 yuv420p 转成 420v（NV12）的 CVPixelBuffer（M04P14/M04P18）")
    func softwareDecodePath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libavsoft-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30)

        let input = LibavInput()
        defer { input.close() }
        #expect(input.open(url: url.path, headers: [:]) == nil)

        let decoder = LibavVideoDecoder()
        defer { decoder.close() }
        #expect(decoder.open(input: input, decoderMode: .software) == nil)

        let frames = decoder.decodeFrames(5)
        #expect(frames.count == 5)
        let allSoftware = frames.allSatisfy { !$0.isHardware }
        #expect(allSoftware)
        let first = try #require(frames.first)
        // 软解统一转 420v：到了显示层那边，硬解帧与软解帧走的是同一条路
        #expect(CVPixelBufferGetPixelFormatType(first.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetPlaneCount(first.pixelBuffer) == 2)
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == 320)
        #expect(CVPixelBufferGetHeight(first.pixelBuffer) == 240)
        #expect(abs(first.seconds) < 0.001)
        let second = try #require(frames.dropFirst().first)
        #expect(abs(second.seconds - 1.0 / 30.0) < 0.002)
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
        let openFailure = decoder.open(input: input, decoderMode: .hardware)
        #expect(openFailure == nil)

        let frames = decoder.decodeFrames(5)
        #expect(frames.count == 5)
        // 硬解模式下这里必须是 VT 直出的帧（软解帧现在也收，别让它把这条断言糊过去）
        let allHardware = frames.allSatisfy { $0.isHardware }
        #expect(allHardware)
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
