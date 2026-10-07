import Foundation
import Testing

@testable import CatVodPlayer

@Suite("播放内核可用性")
struct PlayerEngineTests {
    @Test("M3 启用 MPVKit 前，mpv 内核报告不可用而非崩溃")
    func mpvAvailability() {
        let kind = PlayerEngineKind.mpv
        // 在未引入 MPVKit 的构建里应为 false；引入后由 #if canImport(Libmpv) 打开。
        #expect(kind.isAvailable == false)
    }

    @Test("播放错误文案可直接展示")
    func errorMessages() {
        #expect(PlayerError.engineUnavailable(.mpv).message.contains("mpv"))
        #expect(PlayerError.invalidURL("http://x").message.contains("http://x"))
        #expect(PlayerError.unsupportedFeature("Widevine").message.contains("Widevine"))
    }

    @Test("播放状态判定")
    func stateHelpers() {
        #expect(PlayerState.playing.isPlaying)
        #expect(!PlayerState.paused.isPlaying)
        #expect(PlayerState.failed("x") != PlayerState.idle)
    }
}
