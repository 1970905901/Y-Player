import AudioToolbox
@testable import CatVodPlayer
import CoreMedia
import Foundation
import Testing

/// PCM → 音频样本（M04P10）：纯转换，不碰解码器。
@Suite("PCM → 音频样本（M04P10）")
struct LibavAudioSampleBufferTests {
    @Test("格式 / 帧数 / 时间戳都对上，ASBD 是 Float32 交错")
    func wrapsPCM() throws {
        let frames = 1024
        let channels = 2
        let byteCount = frames * channels * MemoryLayout<Float>.size
        let raw = try #require(malloc(byteCount))
        memset(raw, 0, byteCount)

        let sample = try #require(LibavAudioSampleBuffer.make(
            ownedPCM: raw,
            frameCount: frames,
            sampleRate: 44100,
            channels: channels,
            presentationSeconds: 2.5
        ))
        #expect(CMSampleBufferGetNumSamples(sample) == frames)
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - 2.5) < 0.0001)
        #expect(abs(CMSampleBufferGetDuration(sample).seconds - Double(frames) / 44100) < 0.0001)

        let description = try #require(CMSampleBufferGetFormatDescription(sample))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        #expect(asbd.pointee.mSampleRate == 44100)
        #expect(asbd.pointee.mChannelsPerFrame == 2)
        #expect(asbd.pointee.mBitsPerChannel == 32)
        #expect(asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        #expect(asbd.pointee.mFormatFlags & kAudioFormatFlagIsPacked != 0)
    }

    @Test("坏参数：给 nil（内存由本函数自己收）")
    func rejectsBadInput() throws {
        let raw = try #require(malloc(16))
        let sample = LibavAudioSampleBuffer.make(
            ownedPCM: raw,
            frameCount: 0,
            sampleRate: 44100,
            channels: 2,
            presentationSeconds: 0
        )
        #expect(sample == nil)
    }
}
