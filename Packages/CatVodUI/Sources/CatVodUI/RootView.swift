import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 应用根视图。
///
/// 当前阶段（M2）：两个原生 Tab —— 「接口」负责加载/管理源，加载完成后「首页」用于浏览与播放。
///
/// UI 约定：导航/列表/工具栏一律通过 ``AdaptiveNavigationContainer``、``adaptiveListStyle()``、
/// ``adaptiveToolbar(leading:trailing:)`` 获取**当前系统的原生外观**，业务视图不写版本分支。
/// macOS 的双栏/侧边栏形态（`NavigationSplitView`）需 iOS 16+/macOS 13+，在 M9 通过 Platform 层补充，
/// 不在业务视图里做版本判断。
///
/// 标注 `@MainActor`：根视图构造 `AppModel`（`@MainActor` 隔离），显式标注可在 Swift 5 / 6 语言模式下都正确编译。
@MainActor
public struct RootView: View {
    @StateObject private var model = AppModel()

    public init() { }

    public var body: some View {
        TabView {
            AdaptiveNavigationContainer {
                InterfaceManagementView(model: model)
            }
            .tabItem {
                Label("接口", systemImage: "antenna.radiowaves.left.and.right")
            }

            AdaptiveNavigationContainer {
                HomeView(model: model)
            }
            .tabItem {
                Label("首页", systemImage: "house")
            }
        }
        .task {
            // 冷启动恢复：本地保存了接口地址就自动加载一次，不必先去「接口」页手动点「加载」；
            // 加载完成会自增 `siteCatalogRevision`，首页/搜索据此拿到站点（见 M02P9）。
            await model.loadSavedSourceIfNeeded()
        }
    }
}
