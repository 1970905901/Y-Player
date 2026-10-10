import AudioToolbox
@testable import CatVodPlayer
import CoreMedia
import Foundation
import Testing

/// Libav 音频解码（M04P10）：真解码器 + swresample + `TinyMP4Fixture`（带 AAC 音轨）。
///
/// 用统一 demux（`LibavInput.nextPacket`）喂包 —— 与将来会话的路数一致。
@Suite("Libav 音频解码（M04P10）")
struct LibavAudioDecoderTests {
    @Test("拿到的下标不是音频流：明确拦住（M04P16 换轨的入口要靠它）")
    func rejectsNonAudioStream() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-none-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30)

        let input = LibavInput()
        defer { input.close() }
        #expect(input.open(url: url.path, headers: [:]) == nil)

        let decoder = LibavAudioDecoder()
        defer { decoder.close() }
        // 这个文件只有视频流：把视频流的下标当音轨喂进去，得拦住（会话那边压根不会建解码器）
        let videoIndex = try #require(input.firstStreamIndex(of: .video))
        let failure = decoder.open(input: input, streamIndex: videoIndex)
        #expect(failure != nil)
        #expect(failure?.contains("不是音频流") == true)
    }

    @Test("带音轨的小文件：解出 44.1kHz / 双声道 PCM，时间戳起步、衔接得上")
    func decodesAudio() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(
            to: url,
            width: 320,
            height: 240,
            fps: 30,
            frames: 30,
            audioSeconds: 1.0
        )

        let input = LibavInput()
        defer { input.close() }
        #expect(input.open(url: url.path, headers: [:]) == nil)

        let decoder = LibavAudioDecoder()
        defer { decoder.close() }
        let audioIndex = try #require(input.firstStreamIndex(of: .audio))
        let openFailure = decoder.open(input: input, streamIndex: audioIndex)
        #expect(openFailure == nil)
        #expect(decoder.streamIndex == audioIndex)

        var samples: [CMSampleBuffer] = []
        while let packet = input.nextPacket() {
            if packet.streamIndex == decoder.streamIndex {
                samples.append(contentsOf: decoder.feed(packet.pointer))
            }
        }
        samples.append(contentsOf: decoder.drain())
        #expect(input.isAtEnd)
        #expect(!samples.isEmpty)

        let first = try #require(samples.first)
        let description = try #require(CMSampleBufferGetFormatDescription(first))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        #expect(asbd.pointee.mSampleRate == 44100)
        #expect(asbd.pointee.mChannelsPerFrame == 2)

        // 1 秒 44.1kHz；AAC 有 priming，量级对即可
        let totalFrames = samples.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
        #expect(totalFrames > 40000)
        #expect(totalFrames < 60000)

        // 时间戳起步、逐块衔接（容一点 AAC 块边界的舍入）
        #expect(CMSampleBufferGetPresentationTimeStamp(first).seconds > -0.1)
        for (previous, next) in zip(samples, samples.dropFirst()) {
            let previousEnd = CMSampleBufferGetPresentationTimeStamp(previous).seconds
                + CMSampleBufferGetDuration(previous).seconds
            #expect(CMSampleBufferGetPresentationTimeStamp(next).seconds >= previousEnd - 0.02)
        }
    }
}
