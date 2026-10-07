import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 应用根视图。
///
/// 三个原生 Tab（对齐 `docs/任务记录/M02P11-设置页与追剧页.md` 的参考图信息架构）：
/// - 「发现」= ``HomeView``：浏览与播放（原来的首页）；
/// - 「追剧」= ``LibraryView``：播放历史 / 收藏记录；
/// - 「设置」= ``SettingsView``：源地址、首页展示方式、播放（内核/解码/弹幕解析）、
///   数据（下载/缓存/日志）、iCloud 同步。
///
/// 原来的「接口管理」页不再是独立 Tab，而是「设置 → 源地址」的详情页（``InterfaceManagementView``）。
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
                HomeView(model: model)
            }
            .tabItem {
                Label("发现", systemImage: "play.rectangle")
            }

            AdaptiveNavigationContainer {
                LibraryView(model: model)
            }
            .tabItem {
                Label("追剧", systemImage: "heart")
            }

            AdaptiveNavigationContainer {
                SettingsView(model: model)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
        }
        .task {
            // 冷启动恢复：本地保存了接口地址就自动加载一次，不必先去「设置 → 源地址」手动点「加载」；
            // 加载完成会自增 `siteCatalogRevision`，首页/搜索/追剧据此拿到站点（见 M02P9）。
            await model.loadSavedSourceIfNeeded()
        }
    }
}
