import SwiftUI

/// 平台差异 shim：把 iOS 15 / macOS 13 的差异集中在这里，业务代码不做散落的 `#if`。
public enum PlatformShims {
    /// 跨平台颜色（`Color` 在两平台同名，这里只留扩展点）。
    public static let accent = Color.accentColor

    /// 卡片圆角。
    public static let cardCornerRadius: CGFloat = 10
}

public extension View {
    /// 搜索框「永不自动首字母大写」。
    ///
    /// `textInputAutocapitalization` 是 **iOS-only**：直接写在视图里会让 macOS 编译不过（CI 就是这么红的）。
    /// 平台差异收敛到 shim —— 这是本仓库的规矩。`#if` 内按 `.swiftformat` 的 `--ifdef no-indent` 不额外缩进。
    func platformTextInputAutocapitalizationNever() -> some View {
        #if os(iOS)
        return textInputAutocapitalization(.never)
        #else
        return self
        #endif
    }
}
