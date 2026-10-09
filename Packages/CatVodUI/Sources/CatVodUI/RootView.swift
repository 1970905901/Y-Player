import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 应用根视图。
///
/// 四个原生 Tab：
/// - 「发现」= ``HomeView``：浏览与播放（原来的首页）；
/// - 「直播」= ``LiveView``：直播源 / 分组 / 频道 / 节目单 / 收藏（M07c；入口从发现页工具栏的
///   纸飞机按钮改成底部 Tab，见 `docs/任务记录/M07c6-直播入口改底部Tab.md`）；
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
    /// 四个 Tab **各一份**的沉浸页登记簿（详情 / 播放压上来时收起底部 Tab 栏；
    /// 机制与原因见 `Platform/AdaptiveTabBar.swift`）。一份只服务一个 Tab。
    @StateObject private var discoverImmersiveTabBar = ImmersiveTabBarState()
    @StateObject private var liveImmersiveTabBar = ImmersiveTabBarState()
    @StateObject private var libraryImmersiveTabBar = ImmersiveTabBarState()
    @StateObject private var settingsImmersiveTabBar = ImmersiveTabBarState()

    public init() { }

    public var body: some View {
        TabView {
            AdaptiveNavigationContainer {
                HomeView(model: model)
            }
            .environmentObject(discoverImmersiveTabBar)
            .tabItem {
                Label("发现", systemImage: "play.rectangle")
            }

            AdaptiveNavigationContainer {
                LiveView(model: model)
            }
            .environmentObject(liveImmersiveTabBar)
            .tabItem {
                Label("直播", systemImage: "dot.radiowaves.left.and.right")
            }

            AdaptiveNavigationContainer {
                LibraryView(model: model)
            }
            .environmentObject(libraryImmersiveTabBar)
            .tabItem {
                Label("追剧", systemImage: "heart")
            }

            AdaptiveNavigationContainer {
                SettingsView(model: model)
            }
            .environmentObject(settingsImmersiveTabBar)
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
        }
        .task {
            // 冷启动恢复：本地保存了接口地址就自动加载一次，不必先去「设置 → 源地址」手动点「加载」；
            // 加载完成会自增 `siteCatalogRevision`，首页/搜索/追剧据此拿到站点（见 M02P9）。
            await model.loadSavedSourceIfNeeded()
            // 本机代理服务（M6）：启动时就起来，播放时才有端口可用
            // （`playbackResource(_:)` 是同步判定，不能在那里 await）。
            await model.ensureLocalServer()
        }
    }
}
