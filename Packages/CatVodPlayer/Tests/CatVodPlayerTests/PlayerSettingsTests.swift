import CatVodCore
import Foundation
import Testing

@testable import CatVodPlayer

/// 播放设置：**手动选择内核与解码方式，不做自动降级**。
@MainActor
@Suite("播放设置：手动选择，不自动降级")
struct PlayerSettingsTests {
    @Test("选中的内核不可用时不降级，只返回原因")
    func strictNoFallback() {
        let coordinator = PlayerCoordinator()
        let resolution = coordinator.resolve(settings: PlaybackSettings(engine: .mpv, decoderMode: .hardware))
        guard case let .unavailable(kind, reason) = resolution else {
            Issue.record("MPV 未接入时应返回 unavailable，而不是悄悄换成别的内核")
            return
        }
        #expect(kind == .mpv)
        #expect(reason.contains("M3"))
    }

    @Test("系统内核可用：严格按用户选择执行")
    func systemReady() {
        let coordinator = PlayerCoordinator()
        let resolution = coordinator.resolve(settings: PlaybackSettings(engine: .system, decoderMode: .software))
        #expect(resolution == .ready(.system))
        #expect(coordinator.makeEngine(kind: .system, decoderMode: .software) != nil)
    }

    @Test("未接入的内核不创建实例（需提示用户修改设置，而不是降级）")
    func unimplementedEngines() {
        let coordinator = PlayerCoordinator()
        #expect(coordinator.makeEngine(kind: .mpv, decoderMode: .hardware) == nil)
        #expect(coordinator.makeEngine(kind: .ffmpeg, decoderMode: .hardware) == nil)
    }

    @Test("解码方式有效性：系统内核不支持强制硬解/软解")
    func decoderModeSupport() {
        #expect(!DecoderMode.hardware.isSupported(by: .system))
        #expect(DecoderMode.hardware.isSupported(by: .mpv))
        #expect(DecoderMode.software.isSupported(by: .ffmpeg))
        #expect(!PlaybackSettings(engine: .system, decoderMode: .software).isDecoderModeEffective)
        #expect(PlaybackSettings(engine: .mpv, decoderMode: .software).isDecoderModeEffective)
    }

    @Test("系统内核记录解码方式并报告初始状态")
    func systemEngineLifecycle() async throws {
        let engine = AVPlayerEngine(decoderMode: .software)
        #expect(engine.kind == .system)
        #expect(engine.decoderMode == .software)

        let state = await engine.currentState()
        #expect(state == .idle)

        await #expect(throws: PlayerError.self) {
            try await engine.load(MediaResource(url: "not a url"))
        }
        await engine.teardown()
        engine.finishEvents()
    }

    @Test("携带 header 时构造 asset 不崩溃")
    func assetWithHeaders() throws {
        let url = try #require(URL(string: "https://cdn.example.com/a.m3u8"))
        _ = AVPlayerEngine.makeAsset(url: url, headers: ["User-Agent": "YPlayer"])
        _ = AVPlayerEngine.makeAsset(url: url, headers: [:])
    }

    @Test("内核与解码方式的展示名、枚举完整性")
    func displayNames() {
        #expect(PlayerEngineKind.allCases.count == 3)
        #expect(DecoderMode.allCases.count == 2)
        #expect(PlayerEngineKind.system.displayName == "系统播放器")
        #expect(PlayerEngineKind.mpv.displayName == "MPV")
        #expect(DecoderMode.hardware.displayName == "硬件解码")
        #expect(DecoderMode.software.displayName == "软件解码")
    }
}
