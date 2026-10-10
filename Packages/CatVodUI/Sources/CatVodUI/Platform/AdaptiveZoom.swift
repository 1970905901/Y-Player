import SwiftUI

/// 双指捏合的版本分支（`docs/UI 规范.md` 第二节：差异只许收在基础件里，业务视图不写 `#available`）。
///
/// | 平台/版本 | 实现 | 说明 |
/// | --- | --- | --- |
/// | iOS 17+ / macOS 14+ | `MagnifyGesture` | 系统新的捏合手势（带焦点信息，这里用不到） |
/// | iOS 15–16 / macOS 13 | `MagnificationGesture` | 该版本唯一的原生等价物 —— 它从 iOS 17 起被弃用，所以是**故意保留的版本兼容写法** |
///
/// 为什么不用 `MagnifyGesture` 的那点焦点信息（`startAnchor`）：iOS 15 那条给不了，
/// 锚点两边不一致会让手感跳变 —— 统一按**画面中心**缩放（M03P14 记过这条取舍）。
public extension View {
    /// 挂一条「双指捏合」：`onChanged` 给的是**当前倍数**（相对捏合开始），`onEnded` 在松手时来一次。
    ///
    /// 走 `simultaneousGesture`：捏合不该把画面上的其它手势掐掉 —— 点按 / 拖动那几条各自有守卫
    /// （`isZooming` 期间它们不做事，见 `PlaybackView+Gestures.swift`）。
    @ViewBuilder
    func adaptiveMagnificationGesture(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            simultaneousGesture(
                MagnifyGesture()
                    .onChanged { onChanged($0.magnification) }
                    .onEnded { _ in onEnded() }
            )
        } else {
            simultaneousGesture(
                MagnificationGesture()
                    .onChanged { onChanged($0) }
                    .onEnded { _ in onEnded() }
            )
        }
    }
}
