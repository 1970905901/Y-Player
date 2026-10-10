import AVFoundation
@testable import CatVodPlayer
import CoreMedia
import Foundation
import Testing

/// 音频渲染器（M04P10）：喂块 / 音量的冒烟测试。
///
/// 真出声要上机（渲染器不挂设备时单测只能验**不炸**）。
@Suite("音频渲染器（M04P10）")
struct LibavAudioRendererTests {
    @Test("喂一块 PCM 不炸；音量 / 清队都安全")
    func rendererSmoke() throws {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let renderer = LibavAudioRenderer(synchronizer: synchronizer)

        let frames = 512
        let byteCount = frames * 2 * MemoryLayout<Float>.size
        let raw = try #require(malloc(byteCount))
        memset(raw, 0, byteCount)
        let sample = try #require(LibavAudioSampleBuffer.make(
            ownedPCM: raw,
            frameCount: frames,
            sampleRate: 44100,
            channels: 2,
            presentationSeconds: 0
        ))

        renderer.enqueue(sample)
        renderer.setVolume(0.5)
        renderer.setVolume(1.5)
        renderer.flush()
    }
}
