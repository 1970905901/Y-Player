@testable import CatVodUI
import Foundation
import Testing

/// 宿主探活（M22P1）：三种状态的文案，以及「没有宿主 ≠ 离线」。
@Suite("宿主探活")
struct HostHealthTests {
    @Test("三态文案：unknown / online / offline 各说各的")
    func texts() {
        #expect(HostHealth.unknown.text == "尚未检测")
        #expect(HostHealth.online.text == "在线（刚探过）")
        // 离线那句必须给下一步（点「重启宿主」），不能只说「离线」
        #expect(HostHealth.offline.text.contains("重启宿主"))
    }

    @Test("没有宿主时是 unknown，不是 offline —— 「不需要」不等于「挂了」")
    @MainActor
    func noHostIsUnknown() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        // 内联 JSON 配置：不需要宿主
        await fixture.model.refreshHostHealth()
        #expect(fixture.model.hostHealth == .unknown)
    }
}
