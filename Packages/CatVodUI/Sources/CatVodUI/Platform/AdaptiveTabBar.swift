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
    /// 调用点在 Tab 内容**内部**即可生效：SwiftUI 会把该偏好往上递给所在的 `TabView`。
    /// ⚠️ 若哪天在真机上发现它没有生效，第一件事是把它挪到 `RootView` 里那个 Tab 的内容上
    /// （`AdaptiveNavigationContainer { HomeView(…) }` 之后）—— 那里离 `TabView` 更近。
    /// 挪的时候状态也要跟着上移（`HomeView` 的 `@State` 改成绑给 `RootView`）。
    func adaptiveTabBarHidden(_ isHidden: Bool) -> some View {
        modifier(AdaptiveTabBarHiddenModifier(isHidden: isHidden))
    }
}
