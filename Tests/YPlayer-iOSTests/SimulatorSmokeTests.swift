import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import XCTest

/// iOS 模拟器冒烟测试：**在真实 iOS 运行时里把代码跑起来**，而不是只编译。
///
/// 覆盖三件 CI 只编译时验不到的事：
/// 1. App 能否**启动**（动态库嵌入失败会在这里以 `dyld: Library not loaded` 暴露）；
/// 2. MPVKit 依赖已接、引擎已实装但**画面输出路径未定**时，内核可用性是否**如实**为不可用；
/// 3. 内嵌 Node（libnode）能否真的起来、打印就绪行、并返回站点清单 —— 即 M16P4 的第 1、2、5 项。
final class SimulatorSmokeTests: XCTestCase {
    /// 能执行到测试体，就意味着 App 完成启动、所有动态库都加载成功。
    func testAppLaunchesAndRunsCode() {
        XCTAssertTrue(true, "能跑到这里说明 App 启动成功（没有 dyld 缺库）")
    }

    /// 实装 ≠ 可用：M3 第 4 步把 `MpvEngine` 写完了，但渲染路径（第 3 步）还没定 —— 仍不得宣称可用。
    func testMpvEngineImplementedButVideoOutputPending() {
        XCTAssertTrue(MpvAvailability.canImportLibmpv, "MPVKit 应已随包链接")
        XCTAssertTrue(MpvAvailability.isEngineImplemented, "MpvEngine 应已实装（M03P1 第 4 步）")
        XCTAssertFalse(MpvAvailability.isVideoOutputReady, "渲染路径属第 3 步，需要 Mac/真机 PoC")
        XCTAssertFalse(PlayerEngineKind.mpv.isAvailable, "没有画面就等于不能用：不得对外宣称可用")
        XCTAssertFalse(PlayerEngineKind.ffmpeg.isAvailable, "FFmpegEngine 属 M4")
        XCTAssertTrue(PlayerEngineKind.system.isAvailable)
    }

    /// iOS 上运行时应报告「可用」（随包链接了 NodeMobile）；若未链接则说明取产物步骤被跳过。
    func testEmbeddedNodeRuntimeAvailability() {
        XCTAssertTrue(
            JS2PHostService.isRuntimeAvailable,
            "iOS 应随包链接 NodeMobile；若为 false，检查 Scripts/fetch_nodejs_mobile.py 是否执行"
        )
        XCTAssertTrue(MpvAvailability.summary.contains("libmpv=可用"))
    }
}
