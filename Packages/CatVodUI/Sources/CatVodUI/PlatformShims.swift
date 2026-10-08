import SwiftUI

/// 平台差异 shim：把 iOS 15 / macOS 13 的差异集中在这里，业务代码不做散落的 `#if`。
public enum PlatformShims {
    /// 跨平台颜色（`Color` 在两平台同名，这里只留扩展点）。
    public static let accent = Color.accentColor

    /// 卡片圆角。
    public static let cardCornerRadius: CGFloat = 10
}
