import CatVodCore
@testable import CatVodPlayer
import Foundation
import Testing

/// 播放设置：**手动选择内核与解码方式，不做自动降级**。
@MainActor
@Suite("播放设置：手动选择，不自动降级")
struct PlayerSettingsTests {
    @Test("三个内核都按用户选择解析为 ready：不降级、不替换")
    func strictNoFallback() {
        let coordinator = PlayerCoordinator()
        // M04P13 起自研 FFmpeg 也进了创建路径：不再有「未接入」的内核。
        // 于是三种内核都必须**原样**返回用户选的那个 —— 这才是「不降级」的可断言形态。
        for kind in PlayerEngineKind.allCases {
            let resolution = coordinator.resolve(settings: PlaybackSettings(engine: kind, decoderMode: .hardware))
            #expect(resolution == .ready(kind))
        }
    }

    @Test("MPV 就绪：引擎 + 渲染路径都齐，解析为 ready")
    func mpvReady() {
        let coordinator = PlayerCoordinator()
        #expect(coordinator.resolve(settings: PlaybackSettings(engine: .mpv, decoderMode: .hardware)) == .ready(.mpv))
    }

    @Test("系统内核可用：严格按用户选择执行")
    func systemReady() {
        let coordinator = PlayerCoordinator()
        let resolution = coordinator.resolve(settings: PlaybackSettings(engine: .system, decoderMode: .software))
        #expect(resolution == .ready(.system))
        #expect(coordinator.makeEngine(kind: .system, decoderMode: .software) != nil)
    }

    @Test("自绘内核没画面层就不创建实例（需提示用户修改设置，而不是降级）")
    func surfacelessEngines() {
        let coordinator = PlayerCoordinator()
        // 系统内核不用画面层，照建。
        #expect(coordinator.makeEngine(kind: .system, decoderMode: .hardware) != nil)
        // 两个自绘内核（MPV / 自研 FFmpeg）没给画面层都建不出来 —— 宁可说「不可用」。
        #expect(coordinator.makeEngine(kind: .mpv, decoderMode: .hardware) == nil)
        #expect(coordinator.makeEngine(kind: .ffmpeg, decoderMode: .hardware) == nil)
        // 给了各自的画面层就建得出来（M04P13：自研 FFmpeg 也进了创建路径）。
        #expect(coordinator.makeEngine(kind: .mpv, decoderMode: .hardware, videoSurface: MpvVideoSurface()) != nil)
        #expect(coordinator.makeEngine(kind: .ffmpeg, decoderMode: .hardware, ffmpegSurface: FFmpegVideoSurface()) != nil)
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
