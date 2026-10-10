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
///   数据（下载/缓存/日志）。
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
    /// 四个 Tab 的标识（`TabView` 的 selection 用它；M07d9 的「开机自启」要能切过去）。
    private enum RootTab: Hashable {
        case discover
        case live
        case library
        case settings
    }

    @StateObject private var model = AppModel()
    /// 当前 Tab；启动 `.task` 里按「开机自启」决定初始落在哪个（默认「发现」）。
    @State private var selectedTab: RootTab = .discover
    /// 四个 Tab **各一份**的沉浸页登记簿（详情 / 播放压上来时收起底部 Tab 栏；
    /// 机制与原因见 `Platform/AdaptiveTabBar.swift`）。一份只服务一个 Tab。
    @StateObject private var discoverImmersiveTabBar = ImmersiveTabBarState()
    @StateObject private var liveImmersiveTabBar = ImmersiveTabBarState()
    @StateObject private var libraryImmersiveTabBar = ImmersiveTabBarState()
    @StateObject private var settingsImmersiveTabBar = ImmersiveTabBarState()
    /// 前后台状态：回到前台要把没下完的接着跑（M10h）。
    @Environment(\.scenePhase) private var scenePhase

    public init() { }

    public var body: some View {
        TabView(selection: $selectedTab) {
            AdaptiveNavigationContainer {
                HomeView(model: model)
            }
            .environmentObject(discoverImmersiveTabBar)
            .tag(RootTab.discover)
            .tabItem {
                Label("发现", systemImage: "play.rectangle")
            }

            AdaptiveNavigationContainer {
                LiveView(model: model)
            }
            .environmentObject(liveImmersiveTabBar)
            .tag(RootTab.live)
            .tabItem {
                Label("直播", systemImage: "dot.radiowaves.left.and.right")
            }

            AdaptiveNavigationContainer {
                LibraryView(model: model)
            }
            .environmentObject(libraryImmersiveTabBar)
            .tag(RootTab.library)
            .tabItem {
                Label("追剧", systemImage: "heart")
            }

            AdaptiveNavigationContainer {
                SettingsView(model: model)
            }
            .environmentObject(settingsImmersiveTabBar)
            .tag(RootTab.settings)
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
        }
        .task {
            // 冷启动恢复：本地保存了接口地址就自动加载一次，不必先去「设置 → 源地址」手动点「加载」；
            // 加载完成会自增 `siteCatalogRevision`，首页/搜索/追剧据此拿到站点（见 M02P9）。
            await model.loadSavedSourceIfNeeded()
            // 开机自启（M07d9）：当前直播源带 `boot`（或本机开关打开）→ 启动直接落在「直播」Tab
            // （上游 `ConfigEvent.BOOT` → `LiveActivity.start`）。只是初始 Tab 不同，别的不动。
            if model.liveBootEnabled {
                selectedTab = .live
            }
            // 本机代理服务（M6）：启动时就起来，播放时才有端口可用
            // （`playbackResource(_:)` 是同步判定，不能在那里 await）。
            // 走「开关 ↔ 服务」的对账入口：开关关着就不会白起服务（M06o）。
            await model.syncLocalServerWithSwitch()
            // 上次没下完的（被挂起 / 杀掉时留下的 `running` 在这里降级成 `waiting`，M10b/M25）：
            // 启动就接着跑，不必先进「下载管理」页（M10h）。
            await model.restoreDownloads()
            model.startDownloadDriverIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else {
                return
            }
            Task {
                // 回前台同样走恢复：挂起期间没跑完的 `running` 降级回排队，再由驱动接手。
                await model.restoreDownloads()
                model.startDownloadDriverIfNeeded()
                // 挂起期间监听 socket 可能已被系统断开（`ensureLocalServer` 的注释）：回前台按开关
                // 再对一次账 —— 该在的幂等 start，关着的不会被顺手起起来（M06o）。
                await model.syncLocalServerWithSwitch()
            }
        }
    }
}
