@testable import CatVodPlayer
import Testing

@MainActor
@Suite("MPV 内核可用性（MPVKit 依赖是否真的生效）")
struct MpvAvailabilityTests {
    @Test("接入 MPVKit 后必须能 import Libmpv —— 否则 MpvEngine 根本写不了")
    func libmpvImportable() {
        #expect(MpvAvailability.canImportLibmpv)
    }

    @Test("Libav* 也应可用（M4 的 FFmpegEngine 复用同一套二进制）")
    func libavcodecImportable() {
        #expect(MpvAvailability.canImportLibavcodec)
    }

    @Test("实装 + 渲染路径接线 ⇒ MPV 才是可用（M03P1 第 3/4 步都齐）")
    func engineAndVideoOutputReady() {
        // 这一对断言是接入 MPVKit 时暴露出的真问题：只要看 canImport 就返回 true，
        // 界面会宣称 MPV 可用却播不了。两者必须分开。
        #expect(MpvAvailability.canImportLibmpv)
        #expect(MpvAvailability.isEngineImplemented)
        #expect(MpvAvailability.isVideoOutputReady)
        #expect(PlayerEngineKind.mpv.isAvailable)
        #expect(PlayerEngineKind.ffmpeg.isAvailable == false)
        #expect(PlayerEngineKind.system.isAvailable)
    }

    @Test("没给画面层就建不出 MPV 内核：宁可说不可用，也不给一个没有画面的播放器")
    @MainActor
    func mpvRequiresVideoSurface() {
        let coordinator = PlayerCoordinator()
        #expect(coordinator.makeEngine(kind: .mpv, decoderMode: .hardware) == nil)
        #expect(coordinator.makeEngine(
            kind: .mpv,
            decoderMode: .hardware,
            videoSurface: MpvVideoSurface()
        ) != nil)
    }
}
