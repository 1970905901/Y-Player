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

    @Test("音量增益（M04P23）：同一份源解两遍 —— gain 1.5 的峰值恰是 1.5 倍；纯函数那半夹到 ±1")
    func gainScalesSamples() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-gain-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(
            to: url,
            width: 320,
            height: 240,
            fps: 30,
            frames: 30,
            audioSeconds: 1.0,
            toneAmplitude: 0.5
        )

        let plain = try decodePeak(url: url, gain: 1)
        let boosted = try decodePeak(url: url, gain: 1.5)
        // 源真的有声音（0.5 的 440Hz）——不然这个测试什么都没验
        #expect(plain > 0.2)
        // 同一份源、同一个解码器：乘增益是逐样本的，峰值之比恰是 1.5（不夹顶时）
        #expect(abs(boosted - plain * 1.5) < 0.001)

        // 夹紧那半（纯函数）：超满刻度的样本不许绕回去（那是破音里最难听的一种）
        #expect(LibavAudioDecoder.gained(0.8, gain: 2) == 1)
        #expect(LibavAudioDecoder.gained(-0.8, gain: 2) == -1)
        #expect(LibavAudioDecoder.gained(0.25, gain: 1.5) == 0.375)
    }

    /// 解一遍整条音轨、读峰值（增益测试用：同一份源换个 gain 再解一遍即可比）。
    private func decodePeak(url: URL, gain: Float) throws -> Float {
        let input = LibavInput()
        defer { input.close() }
        #expect(input.open(url: url.path, headers: [:]) == nil)
        let audioIndex = try #require(input.firstStreamIndex(of: .audio))
        let decoder = LibavAudioDecoder()
        defer { decoder.close() }
        decoder.gain = gain
        #expect(decoder.open(input: input, streamIndex: audioIndex) == nil)

        var peak: Float = 0
        while let packet = input.nextPacket() {
            if packet.streamIndex == decoder.streamIndex {
                for sample in decoder.feed(packet.pointer) {
                    peak = max(peak, TinyMP4Fixture.peak(of: sample))
                }
            }
        }
        for sample in decoder.drain() {
            peak = max(peak, TinyMP4Fixture.peak(of: sample))
        }
        return peak
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
