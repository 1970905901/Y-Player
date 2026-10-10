import CatVodCore
import SwiftUI

/// 播放页的**弹幕区**（M03P18 起，M03P24 / M03P25 长成三件事）：就地开关 + 「弹幕设置…」+「选择弹幕…」。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数又顶到 SwiftLint 的 `file_length` error（800）——
/// 与 `+Gestures` / `+Controls` / `+Speed` / `+OpeningEnding` / `+Lines` 同一套做法（拆职责，不拆碎）。
/// 跨文件的成员不能带 `private`：两个面板的 `@State`（在主声明里）因此去掉了 `private`。
extension PlaybackView {
    /// 「弹幕」区：就地开关 +「弹幕设置…」（M03P24）+「选择弹幕…」（M03P25）。
    ///
    /// 「弹幕设置…」与开关只在**这一集真有弹幕行**时出现（不摆假开关，「显示」这种设置没弹幕时也无意义）。
    /// 「选择弹幕…」只要**有候选**就能用 —— 那正是它要解决的场景：自动挑的那条没内容，换一条。
    /// 去掉 `private`：主文件把这一块排进信息区（`danmakuSection`），跨文件看得见才行。
    @ViewBuilder
    var danmakuSection: some View {
        if showsDanmakuSection {
            Section("弹幕") {
                if let onDanmakuDisplayChanged, !danmakuLines.isEmpty {
                    Toggle("显示弹幕", isOn: Binding(
                        get: { danmakuDisplay.isVisible },
                        set: { next in
                            var copy = danmakuDisplay
                            copy.isVisible = next
                            onDanmakuDisplayChanged(copy)
                        }
                    ))
                    Button("弹幕设置…") {
                        isDanmakuSettingsPresented = true
                    }
                }
                if danmakuSwitcher != nil {
                    Button("选择弹幕…") {
                        isDanmakuPickerPresented = true
                    }
                }
            }
        }
    }

    /// 「弹幕」区是否出现（M03P18 / M03P24 / M03P25）：**有得可管**才出现 ——
    /// 要么这一集真有弹幕行（能开关 / 能调显示），要么有候选可选（能换一条）；
    /// 两样都没有就不摆这一块（不摆假开关、假入口；上游那颗弹幕按钮同样只在 `haveDanmaku()` 时露出来）。
    private var showsDanmakuSection: Bool {
        let canControl = onDanmakuDisplayChanged != nil || danmakuSwitcher != nil
        let hasSomething = !danmakuLines.isEmpty || danmakuSwitcher?.candidates.isEmpty == false
        return canControl && hasSomething
    }

    /// 弹幕配置的绑定：读上层给的这一份、写回上层（播放页不认识 `AppModel`）。
    /// 快捷面板（``PlaybackDanmakuSettings``）拿它改五项 —— 改一次回写一次，播放中当场生效。
    var danmakuSettingsBinding: Binding<DanmakuDisplayConfig> {
        Binding(
            get: { danmakuDisplay },
            set: { onDanmakuDisplayChanged?($0) }
        )
    }
}
