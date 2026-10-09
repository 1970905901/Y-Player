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

/// 版本自适应的导航标题样式：`inline` 是 iOS 的原生小标题，macOS 没有这个形态（原样返回）。
public extension View {
    /// 把导航标题设为「内联」小标题（发现页的参考版式：标题与工具栏同一行，不占大标题高度）。
    func adaptiveInlineNavigationTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}

/// 版本自适应的「内嵌搜索栏」：搜索框放在导航栏**中间**，右侧可放一个按钮。
///
/// 参考录屏的搜索页就是这个形态：返回箭头 + 搜索框 + 圆形按钮在**同一行**。
/// 系统搜索栏（`.searchable`）只能出现在标题下方的抽屉里，没法与返回按钮同行，
/// 所以搜索框按录屏自绘（圆角浅灰底 + 占位文字），放置位则用系统的原生工具栏槽位：
///
/// | 平台/版本 | 放置位 |
/// | --- | --- |
/// | iOS 15+ | `.principal`（导航栏中间）+ `.topBarTrailing` |
/// | macOS 13+ | 工具栏没有 `.principal`，用默认放置 + `.primaryAction`（等价观感） |
public struct AdaptiveSearchBarModifier<Trailing: View>: ViewModifier {
    @Binding private var text: String
    private let prompt: String
    private let trailing: Trailing

    public init(text: Binding<String>, prompt: String, @ViewBuilder trailing: () -> Trailing) {
        _text = text
        self.prompt = prompt
        self.trailing = trailing()
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItem(placement: .principal) { field }
            ToolbarItem(placement: .topBarTrailing) { trailing }
        }
        #else
        content.toolbar {
            ToolbarItem(placement: .automatic) { field }
            ToolbarItem(placement: .primaryAction) { trailing }
        }
        #endif
    }

    /// 搜索框本体：圆角浅灰底 + 占位文字（录屏里框内没有放大镜图标，这里也不加）。
    private var field: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .submitLabel(.search)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

public extension View {
    /// 把「内嵌搜索框 + 右侧按钮」放进导航栏（iOS 与返回按钮同一行；macOS 用等价放置）。
    func adaptiveSearchBar<Trailing: View>(
        text: Binding<String>,
        prompt: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(AdaptiveSearchBarModifier(text: text, prompt: prompt, trailing: trailing))
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

// MARK: - 半屏 sheet

/// 版本自适应的「半屏 sheet」：iOS 16+ / macOS 13+ 用系统原生的 `presentationDetents([.medium])`
/// 加拖拽指示条；iOS 15 没有半屏形态，回落**该版本原生**的整页 sheet（不跨版本仿制，见文件头规则）。
public struct AdaptiveHalfSheetModifier: ViewModifier {
    public func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            content
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

public extension View {
    /// 把 sheet 限制成半屏（剧集列表抽屉用：参考图里它只占半屏，上面的详情还看得见）。
    func adaptiveHalfSheet() -> some View {
        modifier(AdaptiveHalfSheetModifier())
    }
}
