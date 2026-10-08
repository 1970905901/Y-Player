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

    @Test("实装 ≠ 可用：引擎已写完，但渲染路径未定 —— 仍不得宣称可用")
    func dependencyLinkedButEngineNotImplemented() {
        // 这一对断言是接入 MPVKit 时暴露出的真问题：只要看 canImport 就返回 true，
        // 界面会宣称 MPV 可用却播不了。两者必须分开。
        #expect(MpvAvailability.canImportLibmpv)
        // M3 第 4 步：引擎代码齐了（MpvEngine + MpvEventMapping）
        #expect(MpvAvailability.isEngineImplemented)
        // 但画面输出（第 3 步）还没定 —— 没有画面就等于不能用
        #expect(MpvAvailability.isVideoOutputReady == false)
        #expect(PlayerEngineKind.mpv.isAvailable == false)
        #expect(PlayerEngineKind.ffmpeg.isAvailable == false)
        #expect(PlayerEngineKind.system.isAvailable)
        // 不可用原因要说清「不是没写，是渲染没定」，别让用户以为要等下一个大版本
        let reason = PlayerCoordinator.unavailableReason(for: .mpv)
        #expect(reason.contains("M3"))
        #expect(reason.contains("画面输出"))
    }
}
