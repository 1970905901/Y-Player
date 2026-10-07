import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 应用根视图。
///
/// 当前阶段（M2 第一批）：以「接口管理 + 站点清单 + 播放内核状态」形成最小可用闭环的入口；
/// 后续接入首页/分类/详情/播放页。
///
/// UI 约定：导航/列表/工具栏一律通过 ``AdaptiveNavigationContainer``、``adaptiveListStyle()``、
/// ``adaptiveToolbar(leading:trailing:)`` 获取**当前系统的原生外观**，业务视图不写版本分支。
///
/// 标注 `@MainActor`：根视图构造 `AppModel`（`@MainActor` 隔离），显式标注可在 Swift 5 / 6 语言模式下都正确编译。
@MainActor
public struct RootView: View {
    @StateObject private var model = AppModel()

    public init() {}

    public var body: some View {
        AdaptiveNavigationContainer {
            InterfaceManagementView(model: model)
        }
    }
}
