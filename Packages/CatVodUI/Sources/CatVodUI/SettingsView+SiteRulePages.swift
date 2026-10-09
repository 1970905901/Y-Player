import CatVodCore
import SwiftUI

// 「站点分组规则」设置页（M06g）。上游这块是 `GroupRuleStore.loadUser()` + `AiGroupRuleStore`
// 加上内置规则的开关；本项目做**内置开关 + 接口规则（可开关、不可改）+ 自建规则**，
// AI 生成那条路要连 AI 服务，页内写明未做（不做「点了没反应」的假开关，见 docs/UI 规范.md）。

/// 规则管理页：列出全部候选规则（内置 → 接口 → 自建），能开关，能加删自建规则。
struct SiteGroupRulesView: View {
    @ObservedObject var model: AppModel

    @State private var draftName = ""
    @State private var draftRegex = ""
    @State private var draftWrapBracket = false
    @State private var isAddPresented = false

    private var entries: [GroupRuleConfig.Entry] {
        model.siteGroupRuleEntries
    }

    var body: some View {
        List {
            summarySection
            section(title: "内置规则", source: GroupRule.sourceBuiltin, footer: Self.builtinFooter)
            section(title: "接口规则", source: GroupRule.sourceInterface, footer: Self.interfaceFooter)
            section(title: "自建规则", source: GroupRule.sourceUser, footer: Self.userFooter)
            addSection
            noteSection
        }
        .adaptiveListStyle()
        .navigationTitle("站点分组规则")
        .sheet(isPresented: $isAddPresented) {
            addSheet
        }
    }

    // MARK: - 分节

    private var summarySection: some View {
        Section("概览") {
            InfoRow(title: "已启用", value: "\(enabledCount) / \(entries.count) 条")
            Text("分组标签从站点名里抽：规则命中后取第 1 个捕获组当标签，站点面板顶部的分组条按它分组。"
                + "改站点名（面板里长按）之后标签会按新名字重抽。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(title: String, source: String, footer: String) -> some View {
        let items = entries.filter { $0.rule.source == source }
        Section {
            if items.isEmpty {
                Text(source == GroupRule.sourceUser ? "还没有自建规则。" : "这个接口没有给这类规则。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.rule.id) { entry in
                    row(entry)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func row(_ entry: GroupRuleConfig.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: enabledBinding(entry)) {
                Text(entry.rule.name.isEmpty ? entry.rule.id : entry.rule.name)
                    .lineLimit(1)
            }
            if !entry.rule.regex.isEmpty {
                Text(entry.rule.regex)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if !entry.rule.isValid {
                Label("正则编不出来，这条不会生效", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .swipeActions {
            if entry.rule.source == GroupRule.sourceUser {
                Button("删除", role: .destructive) {
                    model.removeSiteUserRule(entry.rule.id)
                }
            }
        }
    }

    private var addSection: some View {
        Section("新增自建规则") {
            Button {
                draftName = ""
                draftRegex = ""
                draftWrapBracket = false
                isAddPresented = true
            } label: {
                Label("添加规则", systemImage: "plus.circle")
            }
        }
    }

    private var noteSection: some View {
        Section("说明") {
            Text("**AI 生成规则未做**：上游有 `AiGroupRuleStore`（把站点名丢给模型生成正则），"
                + "那条路要连 AI 服务，属于后续里程碑。手动写的规则一样会过安全校验；"
                + "`wrapBracket` 会把抽出来的标签套成 `[标签]`。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 新增弹窗

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("名字（只用于这里显示）", text: $draftName)
                    TextField("正则（要有一个捕获组）", text: $draftRegex)
                        .font(.body.monospaced())
                        .platformTextInputAutocapitalizationNever()
                        .autocorrectionDisabled()
                    Toggle("标签套方括号", isOn: $draftWrapBracket)
                }
                Section {
                    Text("例：`\\[(.+?)\\]` 从 `[主力]某某站` 抽出 `主力`；"
                        + "`(?i)(?:[|｜])\\s*([^|｜]+?)\\s*$` 从 `某某|4K` 抽出 `4K`。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新增规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isAddPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draftRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - 逻辑

    private var enabledCount: Int {
        entries.filter(\.isEnabled).count
    }

    /// 开关的绑定：`set` 不看新值，直接翻本地记录（翻转的唯一入口是 ``AppModel/toggleSiteGroupRule(_:)``）。
    private func enabledBinding(_ entry: GroupRuleConfig.Entry) -> Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { _ in model.toggleSiteGroupRule(entry.rule.id) }
        )
    }

    /// 保存自建规则：**编不出来就不存**（`addSiteUserRule` 返回 false 时弹窗不关，让用户接着改）。
    private func save() {
        guard model.addSiteUserRule(name: draftName, regex: draftRegex, wrapBracket: draftWrapBracket) else {
            return
        }
        isAddPresented = false
    }

    private static let builtinFooter = "内置规则默认生效，除非在这里关掉（上游 `GroupRuleConfig.builtins` 同款四条）。"
    private static let interfaceFooter = "接口配置里给的规则（`groupRules`）：只能开关 —— 改了也会被下次加载覆盖。"
    private static let userFooter = "自己加的规则：左滑删除；删掉后它抽出来的标签立刻从分组条上消失。"
}
