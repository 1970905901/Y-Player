import CatVodCore
import Foundation
import Testing

@testable import CatVodPlayer

@Suite("播放内核选择与降级")
struct PlayerCoordinatorTests {
    @Test("M3/M4 之前：偏好 MPV 时降级到系统播放器，并给出原因")
    func fallbackToSystem() {
        let coordinator = PlayerCoordinator()
        let selection = coordinator.select(preferred: .mpv)
        // 未引入 MPVKit / FFmpeg 内核，兜底顺序 mpv → ffmpeg → system
        #expect(selection.kind == .system)
        #expect(selection.didFallback)
        #expect(selection.reason.contains("MPV"))
    }

    @Test("系统播放器始终可用且可创建")
    func systemAlwaysAvailable() {
        #expect(PlayerEngineKind.system.isAvailable)
        let coordinator = PlayerCoordinator()
        let selection = coordinator.select(preferred: .system)
        #expect(selection.kind == .system)
        #expect(!selection.didFallback)
        #expect(coordinator.makeEngine(kind: .system) != nil)
    }

    @Test("未接入的内核不可创建，且不静默失败")
    func futureEnginesNotCreatable() {
        let coordinator = PlayerCoordinator()
        #expect(coordinator.makeEngine(kind: .mpv) == nil)
        #expect(coordinator.makeEngine(kind: .ffmpeg) == nil)

        let preferred = coordinator.makePreferredEngine(preferred: .ffmpeg)
        #expect(preferred?.engine.kind == .system)
        #expect(preferred?.selection.didFallback == true)
    }

    @Test("内核展示名与枚举完整性")
    func displayNames() {
        #expect(PlayerEngineKind.allCases.count == 3)
        #expect(PlayerEngineKind.system.displayName == "系统播放器")
        #expect(PlayerEngineKind.mpv.displayName == "MPV")
        #expect(PlayerEngineKind.ffmpeg.displayName.contains("FFmpeg"))
    }

    @Test("AVPlayer 内核可构造并报告初始状态")
    func avPlayerEngineLifecycle() async throws {
        let engine = AVPlayerEngine()
        #expect(engine.kind == .system)
        let state = await engine.currentState()
        #expect(state == .idle)

        // 非法地址必须抛错而不是静默失败
        await #expect(throws: PlayerError.self) {
            try await engine.load(MediaResource(url: "not a url"))
        }
        await engine.teardown()
        await engine.finishEvents()
    }

    @Test("携带 header 与起播位置时构造 asset 不崩溃")
    func assetWithHeaders() throws {
        let url = try #require(URL(string: "https://cdn.example.com/a.m3u8"))
        _ = AVPlayerEngine.makeAsset(url: url, headers: ["User-Agent": "YPlayer", "Referer": "https://example.com/"])
        _ = AVPlayerEngine.makeAsset(url: url, headers: [:])
    }
}
