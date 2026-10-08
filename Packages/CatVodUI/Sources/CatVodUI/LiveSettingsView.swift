import CatVodCore
import SwiftUI

/// 直播设置：**直播源**与 **EPG 地址覆盖**（上游：`LiveConfig` 的源列表 + `setting/LiveEpgSetting.java`）。
///
/// 两件事都收在这一页，作为它们**唯一**的入口：
/// - 一个配置里可能有多个直播源（`SourceConfig.lives`），切源在这里 —— 上游也是「先选源再看分组」；
///   只有一个源时**不显示这一组**（上游 `LiveConfig.isOnly()` 同样处理：没什么可切的）。
/// - EPG 地址的本地覆盖：源自己配的 EPG 常常是坏的或过期的，用户手里往往有另一个能用的地址。
///   这里是**全局一份**（上游也是），含 `{id}` / `{name}` / `{date}` 的按频道逐个展开，
///   不含 `{` 的当作「整源一个 XML 文件」。
///
/// 硬要求是「改完立刻生效」：选源即重载清单；改 EPG 即重算频道地址、作废节目单缓存并重拉文件形态。
@MainActor
struct LiveSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.liveEPGSetting.url)
    }

    var body: some View {
        List {
            sourceSection
            groupNameSection
            addressSection
            historySection
            Section("当前状态") {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("直播设置")
        .adaptiveToolbar {
            EmptyView()
        } trailing: {
            Button("完成") {
                dismiss()
            }
        }
    }

    // MARK: - 直播源

    @ViewBuilder private var sourceSection: some View {
        if model.liveSources.count > 1 {
            Section("直播源") {
                ForEach(model.liveSourceRows) { row in
                    sourceRow(row)
                }
            }
        }
    }

    private func sourceRow(_ row: LiveSourceRow) -> some View {
        Button {
            Task { await model.selectLiveSource(row.name) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                    Text(row.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("当前直播源")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组名

    /// 组名里的 `_` 要不要当密码分隔符（上游 `Live.pass`；默认跟源自己的字段）。
    ///
    /// 这个开关是 M07d-4「加密分组默认不显示」的**逃生门**：源里组名本来就有 `_` 的那几个源，
    /// 拆成「名字 + 密码」之后那几组会被当成加密分组**藏起来**，而且永远解锁不了
    /// （密码其实是名字的一部分）。上游留 `pass` 正是为这类源。
    private var groupNameSection: some View {
        Section("分组名") {
            Toggle(isOn: groupPassBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("组名里的 `_` 不当密码")
                    Text("默认跟直播源自己的 `pass` 字段。打开后不再把「组名_密码」拆开；"
                        + "本机覆盖只对当前源生效，改完会重新拉一次清单。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.liveSource == nil)
        }
    }

    /// 开关两个方向都写进本地覆盖（`setLiveGroupPass` 负责落盘 + 重新解析）。
    private var groupPassBinding: Binding<Bool> {
        Binding(
            get: { model.liveGroupPassEnabled },
            set: { enabled in Task { await model.setLiveGroupPass(enabled) } }
        )
    }

    // MARK: - EPG 地址

    private var addressSection: some View {
        Section("EPG 地址") {
            TextField("留空 = 用直播源自己的", text: $draft)
            Button("使用这个地址") {
                Task { await model.updateLiveEPGSetting(draft) }
            }
            .disabled(LiveEPGSetting.normalized(draft) == model.liveEPGSetting.url)
            if model.liveEPGSetting.isActive {
                Button("清除覆盖", role: .destructive) {
                    draft = ""
                    Task { await model.updateLiveEPGSetting("") }
                }
            }
            Text("对所有直播源生效。含 `{id}` / `{name}` / `{date}` 的地址按频道逐个展开；"
                + "不含 `{` 的地址当作「整源一个 XML 文件」，频道不再逐频道请求。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        Section("历史") {
            if model.liveEPGSetting.history.isEmpty {
                Text("还没有用过别的地址。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.liveEPGSetting.history, id: \.self) { entry in
                    historyRow(entry)
                }
                Button("清空历史", role: .destructive) {
                    model.clearLiveEPGHistory()
                }
            }
        }
    }

    private func historyRow(_ entry: String) -> some View {
        HStack(spacing: 8) {
            Button {
                draft = entry
                Task { await model.updateLiveEPGSetting(entry) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry)
                        .font(.footnote)
                        .lineLimit(2)
                    if entry == model.liveEPGSetting.url {
                        Text("正在用")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.removeLiveEPGHistory(entry) }
            } label: {
                Image(systemName: "trash")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从历史里删掉")
        }
    }

    // MARK: - 状态

    /// 当前覆盖在做什么 —— 三种形态说清楚（没覆盖 / 整源文件 / 按频道模板）。
    private var statusText: String {
        let url = model.liveEPGSetting.url
        guard !url.isEmpty else {
            return "没有本地覆盖：用每个直播源自己配的 EPG（XML/GZ 文件或 x-tvg 接口）。"
        }
        if LiveEPGOverride(url: url).isGlobalXML {
            return "本地覆盖生效：\(url) —— 当作整源 XML 文件，频道不再逐频道请求。"
        }
        return "本地覆盖生效：\(url) —— 按频道展开后逐个请求。"
    }
}
