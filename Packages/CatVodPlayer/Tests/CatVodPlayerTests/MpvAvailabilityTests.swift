@testable import CatVodPlayer
import Testing

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

    @Test("依赖链接 ≠ 引擎可用：MPVKit 已接入，但 MpvEngine 未实装")
    func dependencyLinkedButEngineNotImplemented() {
        // 这一对断言是本次接入暴露出的真问题：只要看 canImport 就返回 true，
        // 界面会宣称 MPV 可用却播不了。两者必须分开。
        #expect(MpvAvailability.canImportLibmpv)
        #expect(MpvAvailability.isEngineImplemented == false)
        #expect(PlayerEngineKind.mpv.isAvailable == false)
        #expect(PlayerEngineKind.ffmpeg.isAvailable == false)
        #expect(PlayerEngineKind.system.isAvailable)
    }
}
