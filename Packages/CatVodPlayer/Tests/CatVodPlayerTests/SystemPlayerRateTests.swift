import AVFoundation
@testable import CatVodPlayer
import Testing

/// 系统内核的**倍速**行为。
///
/// 这里钉住的是引擎自己管的那份状态（``AVPlayerEngine/requestedRate``）：`AVPlayer.play()`
/// 等价于「rate 置 1」，所以「设 1.5x → 暂停 → 继续」曾经会悄悄退回正常速度（M02P15 修的就是它）。
///
/// 为什么不断言 `player.rate`：CI 上拿不到 ready 的 `AVPlayerItem`，`AVFoundation` 会在没就绪时
/// 把 rate 自己推回 0，断言它只会得到偶发红。真实生效由真机/模拟器人工确认（见 M02P15 的验收一节）。
@MainActor
@Suite("系统内核：倍速不会被「暂停再播」吃掉")
struct SystemPlayerRateTests {
    @Test("加载资源后回到正常速度（倍速属「本次播放的偏好」，引擎不跨资源记忆）")
    func loadResetsRate() async throws {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        #expect(engine.requestedRate == SpeedSetting.normal)

        await engine.setRate(2.0)
        #expect(engine.requestedRate == 2.0)

        try await engine.load(MediaResource(url: "https://example.com/a.m3u8"))
        #expect(engine.requestedRate == SpeedSetting.normal)

        await engine.teardown()
        engine.finishEvents()
    }

    @Test("音量：0...1 之外的值先夹紧再写进 AVPlayer")
    func volumeIsClamped() async {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        await engine.setVolume(2)
        #expect(engine.systemPlayer().volume == 1)
        await engine.setVolume(-1)
        #expect(engine.systemPlayer().volume == 0)
        await engine.setVolume(0.3)
        #expect(abs(engine.systemPlayer().volume - 0.3) < 0.001)
        await engine.teardown()
        engine.finishEvents()
    }

    @Test("暂停再播不丢倍速（引擎记着用户请求的值）")
    func pauseKeepsRate() async throws {
        let engine = AVPlayerEngine(decoderMode: .software)
        try await engine.load(MediaResource(url: "https://example.com/a.m3u8"))
        await engine.setRate(1.5)
        await engine.play()
        await engine.pause()
        // 这一串之后引擎手上仍然是 1.5 —— `play()` 会按它恢复（旧实现会写死 1.0）
        #expect(engine.requestedRate == 1.5)
        await engine.play()
        #expect(engine.requestedRate == 1.5)

        await engine.teardown()
        engine.finishEvents()
    }

    @Test("setRate 会下发 speedChanged（播放页/设置页据此同步显示）")
    func emitsSpeedChanged() async {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        var iterator = engine.events.makeAsyncIterator()
        await engine.setRate(1.25)
        let event = await iterator.next()
        #expect(event == .speedChanged(1.25))
        #expect(engine.requestedRate == 1.25)
        engine.finishEvents()
    }
}
