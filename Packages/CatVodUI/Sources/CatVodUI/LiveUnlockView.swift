import CatVodCore
import SwiftUI

/// 解锁加密分组（上游 `LiveActivity` 的 `PassListener` + `unlock(pass)`）。
///
/// 背景：源里把分组名写成 `分组名_密码`，这一组就是「加密分组」—— 上游默认**不显示**这些组，
/// 输对密码才把它们搬进分组条（并自动选中第一组）。本项目此前只画了个锁标却照常列频道，
/// 等于「看起来做了、其实没拦」，这一页就是那个洞的补丁。
///
/// 密码来自**源自己的分组名**（不是本机设置），所以这里不帮用户记、也不落盘：
/// 输错就是输错，重启后要重新解锁（上游的 `mHides` 同样只在进程内）。
@MainActor
struct LiveUnlockView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pass = ""
    @State private var isWrongPass = false

    var body: some View {
        List {
            Section("加密分组") {
                SecureField("分组密码", text: $pass)
                Button("解锁") {
                    unlock()
                }
                .disabled(pass.isEmpty)
                if isWrongPass {
                    Text("密码不对。密码是源里「分组名_密码」的后半段，区分大小写。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("说明") {
                Text("还有 \(model.liveLockedGroups.count) 个加密分组没解锁。解锁后会出现在分组条里，"
                    + "本次运行有效（重启后要重新输一次）。密码是源自己定的，本机不保存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("解锁加密分组")
    }

    /// 解锁：成功就退回列表（上游解锁后会自动选中第一组，那件事在 `AppModel.unlockLiveGroups` 里做）。
    private func unlock() {
        isWrongPass = model.unlockLiveGroups(with: pass) == 0
        if !isWrongPass {
            dismiss()
        }
    }
}
