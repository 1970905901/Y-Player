import CatVodCore
import Foundation
import Testing

@testable import CatVodUI

@Suite("UI 平台 shim")
struct PlatformShimsTests {
    @Test("卡片圆角保持稳定值（跨端一致）")
    func cardCornerRadius() {
        #expect(PlatformShims.cardCornerRadius == 10)
    }

    @Test("不可用站点必须有可展示原因")
    func availabilityBadgeReason() {
        let unavailable = SiteAvailability.unavailable(reason: "需要 JVM，Apple 平台不支持 csp_*.jar 站点")
        #expect(unavailable.reason != nil)
        #expect(!unavailable.isAvailable)
        #expect(SiteAvailability.available.reason == nil)
    }
}
