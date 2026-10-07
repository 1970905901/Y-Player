import CatVodCore
import Foundation
import SwiftUI
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

    @Test("版本自适应基础件可构造（编译期验证各版本分支都成立）")
    func adaptiveViewsConstruct() {
        _ = AdaptiveNavigationContainer { Text("root") }
        _ = Text("list").adaptiveListStyle()
        _ = Text("toolbar").adaptiveToolbar(leading: { Text("L") }, trailing: { Text("T") })
        _ = Text("search").adaptiveSearchable(text: .constant(""), prompt: "搜索")
    }
}

