import Foundation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 版本/平台自适应的字体度量。
///
/// 弹幕调度要的「这段文字多宽」只有渲染层答得出来（Core 里没有字体度量，所以
/// ``DanmakuPlan/WidthProvider`` 是注入的）。这里的 `#if os(...)` 按 `docs/UI 规范.md`
/// 只能待在基础件里 —— 业务视图不写平台分支。
public enum AdaptiveFontMetrics {
    /// 一段文字在给定字号下的宽度（点）。
    ///
    /// 字号取弹幕自带的 `size`：上游允许每条弹幕自带字号（`p` 串的第三段），所以宽度是**按行**算的，
    /// 不能用整层一个固定字号去量。
    public static func width(of text: String, size: Double) -> Double {
        guard !text.isEmpty else {
            return 0
        }
        let pointSize = CGFloat(size)
        #if os(iOS)
        let font = UIFont.systemFont(ofSize: pointSize)
        #else
        let font = NSFont.systemFont(ofSize: pointSize)
        #endif
        return Double((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
