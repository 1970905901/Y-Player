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
}
