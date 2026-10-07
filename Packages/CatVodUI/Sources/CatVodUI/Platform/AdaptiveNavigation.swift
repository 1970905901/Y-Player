import SwiftUI

// MARK: - 版本自适应的 UI 约定

//
// 项目规则（**不得违背**）：
//   1. UI 只使用「当前运行系统版本」提供的原生 API 与原生外观，**不做跨版本仿制**
//      （例如不要为了统一观感而在 iOS 18 上模仿 iOS 15 的控件样式）。
//   2. 版本差异通过 `#available` / `#if os(...)` 在**基础件**里收敛，业务视图不写散落的版本分支。
//   3. iOS 15 的最低支持意味着必须为 iOS 15 提供该版本的原生等价实现
//      （如 `NavigationView` + `.stack`），iOS 16+ 自动使用 `NavigationStack`。
//   4. macOS 使用 macOS 原生外观（不使用 iOS 专属样式，如 `.stack` 导航样式）。

/// 版本自适应的导航容器。
///
/// | 平台/版本 | 实现 | 说明 |
/// | --- | --- | --- |
/// | iOS 16+ / iPadOS 16+ | `NavigationStack` | 系统原生新外观、新工具栏与返回手势 |
/// | iOS 15 | `NavigationView` + `.stack` | 该版本唯一的原生等价物 |
/// | macOS 13+ | `NavigationStack` | macOS 原生外观 |
public struct AdaptiveNavigationContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
        #else
        NavigationStack { content }
        #endif
    }
}

/// 版本/平台自适应的列表样式：沿用当前系统的原生列表外观。
public struct AdaptiveListStyleModifier: ViewModifier {
    public func body(content: Content) -> some View {
        #if os(iOS)
        // `.insetGrouped` 是 iOS 的原生分组列表外观（iOS 13+ 起就是系统标准）。
        content.listStyle(.insetGrouped)
        #else
        // macOS 使用系统原生附注列表外观；`.insetGrouped` 在 macOS 上不可用。
        content.listStyle(.inset)
        #endif
    }
}

public extension View {
    /// 应用当前系统原生的列表样式。
    func adaptiveListStyle() -> some View {
        modifier(AdaptiveListStyleModifier())
    }
}

/// 版本自适应的工具栏容器：iOS 16+/macOS 13+ 使用新 `toolbar` 语义，iOS 15 走 `navigationBarItems`。
public struct AdaptiveToolbar<Leading: View, Trailing: View>: ViewModifier {
    private let leading: Leading
    private let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) { leading }
                ToolbarItem(placement: .topBarTrailing) { trailing }
            }
        } else {
            content
                .navigationBarItems(leading: leading, trailing: trailing)
        }
        #else
        content.toolbar {
            ToolbarItem(placement: .navigation) { leading }
            ToolbarItem(placement: .primaryAction) { trailing }
        }
        #endif
    }
}

public extension View {
    /// 同时设置左右工具栏内容，并按系统版本选择原生实现。
    func adaptiveToolbar<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(AdaptiveToolbar(leading: leading, trailing: trailing))
    }
}

/// 版本自适应的可搜索修饰：iOS 15+ 原生 `.searchable`，只在放置位置上做版本区分。
public extension View {
    /// 顶部搜索框（iOS/iPadOS 的原生搜索栏；macOS 走原生工具栏搜索）。
    func adaptiveSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return AnyView(searchable(text: text, prompt: Text(prompt)))
        }
        return AnyView(searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt)))
        #else
        return AnyView(searchable(text: text, prompt: Text(prompt)))
        #endif
    }
}
