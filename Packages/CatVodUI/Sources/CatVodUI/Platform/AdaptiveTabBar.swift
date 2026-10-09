import SwiftUI

// MARK: - 底部 Tab 栏的按需隐藏

/// 版本/平台自适应的「收起底部 Tab 栏」。
///
/// 需求来自 M02P16（发现页上滑隐藏 / 触碰展开），状态机在 ``DiscoverTabBarVisibility``
/// （纯逻辑、有单测）；这里只负责把那个布尔值翻译成**当前系统**的原生 API。
///
/// | 平台/版本 | 实现 |
/// | --- | --- |
/// | iOS 16+ | `.toolbar(.hidden, for: .tabBar)` —— 该位置 iOS 16 才有 |
/// | iOS 15 | **不支持**：没有「按视图隐藏 Tab 栏」的原生 API，见下 |
/// | macOS 13+ | 不适用：macOS 的 `TabView` 不是底部标签栏（`.tabBar` 位置在 macOS 上不可用） |
///
/// iOS 15 为什么不兜底：能做出这个效果的办法只剩去摸 `UITabBarController` 自控系统控件，
/// 与 `docs/UI 规范.md` 的「不做跨版本仿制 / 不自绘系统控件」冲突。所以这里**明着写成空操作**，
/// 而不是留一条会在系统升级后走样的私有路径 —— 缺了就说缺了。
public struct AdaptiveTabBarHiddenModifier: ViewModifier {
    private let isHidden: Bool

    public init(isHidden: Bool) {
        self.isHidden = isHidden
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

public extension View {
    /// 按需收起**当前视图所在的**底部 Tab 栏（不影响其它 Tab）。
    ///
    /// ⚠️ 应用点必须是**栈根页面**（发现页的上滑收起就是这么用的，一直好使）。直接挂在**被推入的页面**
    /// 上在 iOS 26 上是**无效**的：会被栈根页面的显式值压住 —— 2026-10-09 实测，详情页照旧显示 Tab 栏。
    /// 沉浸页（详情 / 播放……）要收 Tab 栏，走 ``ImmersiveTabBarPageModifier``，别用这里。
    func adaptiveTabBarHidden(_ isHidden: Bool) -> some View {
        modifier(AdaptiveTabBarHiddenModifier(isHidden: isHidden))
    }
}

// MARK: - 沉浸页（详情 / 播放……）收起 Tab 栏

/// 每个 Tab 一份的「沉浸页压在栈里」的登记簿。
///
/// 为什么要绕这一圈：`.toolbar(.hidden, for: .tabBar)` 挂在**被推入的页面**上在 iOS 26 上不生效
/// （见 ``AdaptiveTabBarHiddenModifier`` 的说明），好使的位置是**栈根页面**。
/// 所以沉浸页不再自己说话，只在这里登记；由各 Tab 的根页面（``HomeView`` / ``LiveView`` /
/// ``LibraryView`` / ``SettingsView``）读 ``isActive`` 并统一应用。
///
/// 一份登记簿只服务一个 Tab —— `RootView` 给四个 Tab 各注入一份（`.environmentObject`），
/// 免得「发现页还压着详情」时把别的 Tab 的栏也收了。
public final class ImmersiveTabBarState: ObservableObject {
    /// 当前压在栈里的沉浸页数量：详情 → 播放可能叠着两层，所以用计数而不是布尔。
    @Published public private(set) var activePageCount = 0

    /// 本 Tab 是否有沉浸页压在栈里（栈根页面据此收放 Tab 栏）。
    public var isActive: Bool {
        activePageCount > 0
    }

    public init() { }

    /// 沉浸页出现：登记 +1。由 ``ImmersiveTabBarPageModifier`` 调用。
    func notePageAppeared() {
        activePageCount += 1
    }

    /// 沉浸页离场（被更深的页面盖住、或被弹出）：注销 -1。
    func notePageDisappeared() {
        activePageCount = max(0, activePageCount - 1)
    }
}

/// 把「本页是沉浸页」登记给所在 Tab 的 ``ImmersiveTabBarState``：出现 +1、离场 -1。
///
/// 为什么是计数而不是「出现时置 true、离场置 false」：详情 → 播放这种叠两层的场景里，
/// 旧页的 `onDisappear` 与新页的 `onAppear` 在同一次导航更新里先后脚到 ——
/// 计数保证中间不会掉回 0，把 Tab 栏闪出来一帧。
public struct ImmersiveTabBarPageModifier: ViewModifier {
    @EnvironmentObject private var state: ImmersiveTabBarState

    public init() { }

    public func body(content: Content) -> some View {
        content
            .onAppear { state.notePageAppeared() }
            .onDisappear { state.notePageDisappeared() }
    }
}

public extension View {
    /// 标记「这是一张沉浸页」（详情 / 播放……）：它压在栈里的时候，本 Tab 的底部 Tab 栏收起来。
    func immersiveTabBarPage() -> some View {
        modifier(ImmersiveTabBarPageModifier())
    }
}
