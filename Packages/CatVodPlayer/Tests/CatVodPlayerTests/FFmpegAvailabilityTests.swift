@testable import CatVodPlayer
import Testing

/// 自研 FFmpeg 内核（M4）的依赖底座：把「MPVKit 到底给了我们什么」变成可断言的事实。
///
/// 这组断言红了**不要改期望值** —— 红在哪个模块就说明 MPVKit 没给全我们以为它给了的东西，
/// 那是 M4 方案要正面处理的真问题（`missingNames` 与逐模块断言会把名字直接报出来）。
@MainActor
@Suite("FFmpeg 内核依赖探针（M4 地基）")
struct FFmpegAvailabilityTests {
    @Test("六个模块都要能 import —— 缺的那个会出现在失败信息里")
    func allModulesImportable() {
        let missing = FFmpegAvailability.missingNames
        #expect(missing.isEmpty)
        #expect(FFmpegAvailability.availableCount == FFmpegAvailability.probes.count)
    }

    @Test("运行期版本读得到：编译期 import 只是一半，链接也得真通")
    func versionsReadable() {
        // Libass 只报可用性（版本号编码没核实过，不猜）；其余五个必须读到版本号。
        for probe in FFmpegAvailability.probes where probe.name != "Libass" {
            #expect(probe.available)
            #expect(probe.version != nil)
        }
    }

    @Test("版本号写法：AV_VERSION_INT = major << 16 | minor << 8 | micro")
    func versionFormatting() {
        #expect(FFmpegAvailability.versionText(61 << 16 | 19 << 8 | 100) == "61.19.100")
        #expect(FFmpegAvailability.versionText(59 << 16 | 39 << 8 | 100) == "59.39.100")
        #expect(FFmpegAvailability.versionText(0) == "0.0.0")
    }

    @Test("引擎已实装 + 依赖全齐 ⇒ .ffmpeg 可用（M04P13 接线）")
    func engineImplemented() {
        #expect(FFmpegAvailability.isEngineImplemented)
        #expect(FFmpegAvailability.isComplete)
        #expect(PlayerEngineKind.ffmpeg.isAvailable)
    }

    @Test("不可用原因跟着依赖事实走：缺说缺哪个，齐说没给画面层")
    func reasonFollowsFacts() {
        let reason = PlayerCoordinator.unavailableReason(for: .ffmpeg)
        if FFmpegAvailability.isComplete {
            // 依赖齐时唯一还能挡住播放的，就是建引擎没给画面层（UI 不该走到这里，但原因得说真话）。
            #expect(reason.contains("画面层"))
        } else {
            let first = FFmpegAvailability.missingNames.first ?? ""
            #expect(!first.isEmpty)
            #expect(reason.contains(first))
        }
    }
}
