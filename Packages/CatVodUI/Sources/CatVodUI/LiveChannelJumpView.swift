import CatVodCore
import SwiftUI

/// 按**频道号**跳台（上游 `LiveConfig.findByChannelNumber(number, items)`）。
///
/// 号是清单里那个 `number` —— 解析时会给没写号的频道补 `001`、`002`…（上游同样如此），
/// 所以「输 8 跳到 008」这种是最常见的用法。比较时两边能解析成整数就按整数比，
/// 前导零与空白都不影响。
///
/// 找不到就说找不到（不做「悄悄跳到别处」）；也不是数字就直说 ——
/// 上游 `Integer.parseInt` 在这两种输入上会抛异常，界面不该跟着崩。
///
/// 本页**不碰播放**：找到目标就回调给播放页（``LiveChannelPlaybackView/move(to:)``），
/// 由它统一做「改分组 / 改频道 / 线路归零 / 写 keep / 拉节目单」那几件事。
///
/// 刻意不做数字键盘（`.keyboardType` 是 iOS 专有，业务视图不写平台分支，见 `docs/UI 规范.md`）。
@MainActor
struct LiveChannelJumpView: View {
    /// 跳台范围（与播放页拿到的同一份：分组条上看得见的那几组）。
    let groups: [LiveGroup]
    /// 选中后交给调用方切换。
    let onPick: (LiveChannelTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var notice = ""

    var body: some View {
        List {
            Section("频道号") {
                TextField("例如 008", text: $number)
                Button("跳台") {
                    jump()
                }
                .disabled(number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !notice.isEmpty {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("说明") {
                Text("号来自清单：解析时会给没写号的频道按顺序补 001、002…；"
                    + "范围是分组条上看得见的那几组（锁着的加密分组不在里面）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("按号码跳台")
        .adaptiveToolbar {
            EmptyView()
        } trailing: {
            Button("完成") {
                dismiss()
            }
        }
    }

    private func jump() {
        guard let target = LiveChannelNavigation.channel(number: number, in: groups) else {
            notice = "没有这个频道号。号来自清单（没写号的频道会按顺序补 001、002…），换台范围也不含锁着的分组。"
            return
        }
        onPick(target)
        dismiss()
    }
}
