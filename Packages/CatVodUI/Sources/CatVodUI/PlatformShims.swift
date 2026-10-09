import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 平台差异 shim：把 iOS 15 / macOS 13 的差异集中在这里，业务代码不做散落的 `#if`。
public enum PlatformShims {
    /// 复制到系统剪贴板。
    ///
    /// iOS 与 macOS 的 API 完全不同，**只在这一处知道这件事**（业务代码不做 `#if`）。
    /// 诊断报告（M17P1）靠它把一段纯文本交给用户 —— 模拟器与 Mac 的剪贴板是通的，
    /// 复制完直接在 Mac 上粘贴即可。
    @MainActor
    public static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

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
