import CatVodCore
import SwiftUI

// 「广告清理规则」设置页（M06h）。M06d 把清理器 + `/m3u8` 接线做完了，但**没人能开关它** ——
// `HLSAdRuleState`（状态键 + 生效值解析）早就写好了却没人调用。这一页把它接上：
// 列出接口给的 `hlsRules`，每条一个开关，改完立刻重算（`/m3u8` 每个请求现读规则，不用重启本机服务）。

/// 广告规则管理页：列出接口规则、开关、恢复默认。
struct HLSAdRulesView: View {
    @ObservedObject var model: AppModel

    private var entries: [HLSAdRuleState.Entry] {
        model.hlsAdRuleEntries
    }

    var body: some View {
        List {
            summarySection
            builtinSection
            rulesSection
            noteSection
        }
        .adaptiveListStyle()
        .navigationTitle("广告清理规则")
    }

    private var builtinEntries: [HLSAdRuleState.Entry] {
        model.hlsBuiltinRuleEntries
    }

    private var summarySection: some View {
        Section("概览") {
            InfoRow(
                title: "规则",
                value: "内置 \(builtinEntries.count) 条 / 接口 \(entries.count) 条；"
                    + "当前 \(enabledCount) 条生效"
            )
            Text("清理在本机代理里做：`/m3u8` 每个请求**先按规则删广告分片、再改写地址**。"
                + "改开关立刻生效（规则是每次请求现读的），不用重启。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var builtinSection: some View {
        Section {
            if builtinEntries.isEmpty {
                Text("内置规则集当前是空的 —— **这是有意的**：按上游的维护规则，内置规则必须默认关闭，"
                    + "并且要有「该删」与「不该删」两侧的样本证据才收录。"
                    + "资产与加载路径已经就位（`Resources/hls_rules.json`），往里加规则不用改代码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(builtinEntries) { entry in
                    row(entry)
                }
            }
        } header: {
            Text("内置规则包")
        } footer: {
            Text("包里的规则**默认全关**；要用的在这里打开。开关按规则 id 记 —— "
                + "包升级（同一条规则改进匹配条件）不会把你的选择弄丢。")
        }
    }

    private var rulesSection: some View {
        Section {
            if entries.isEmpty {
                Text("这个接口没有给 `hlsRules`。广告清理只在接口自带规则时才有可清的东西。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        } header: {
            Text("接口规则")
        } footer: {
            Text("基准是规则自己写的 `enabled`；这里的开关**覆盖**它 —— 接口说开的可以关，接口没开的也能自己开。"
                + "「恢复默认」把这一条交还给接口的写法。")
        }
    }

    private func row(_ entry: HLSAdRuleState.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: enabledBinding(entry)) {
                HStack(spacing: 6) {
                    Text(entry.rule.name.isEmpty ? entry.rule.id : entry.rule.name)
                        .lineLimit(1)
                    if model.hlsAdRuleOverride(entry.key) != nil {
                        Text("已改")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(scopeSummary(entry.rule))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .swipeActions {
            if model.hlsAdRuleOverride(entry.key) != nil {
                Button("恢复默认") { model.setHLSAdRule(entry.key, enabled: nil) }
            }
        }
    }

    private var noteSection: some View {
        Section("说明") {
            Text("**内置规则包已落地、规则集当前为空**：上游对内置规则的要求是「默认关闭 + 有该删/不该删两侧证据」，"
                + "没证据的规则不进内置集（维护规则记在 `docs/任务记录/M06i`）。"
                + "**「跳过广告」提示仍未做**（播放页不会告诉你「已跳过 N 段」）。"
                + "解析规则里的 `exclude` 兜底不参与开关 —— 那是接口自己的解析规则，不属于广告规则包。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledCount: Int {
        (entries + builtinEntries).filter(\.isEnabled).count
    }

    /// 开关的绑定：翻的是**本地覆盖**（写进 `hlsAdRuleOverrides` 会顺带重算规则并落盘）。
    private func enabledBinding(_ entry: HLSAdRuleState.Entry) -> Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { model.setHLSAdRule(entry.key, enabled: $0) }
        )
    }

    /// 一行作用域摘要：清单 host 后缀 / 正则 —— 规则不写作用域是不允许编译的，所以这里一定有内容。
    private func scopeSummary(_ rule: HLSAdRule) -> String {
        if !rule.playlistHostSuffixes.isEmpty {
            return "清单 host：" + rule.playlistHostSuffixes.joined(separator: "、")
        }
        if !rule.playlistHostRegex.isEmpty {
            return "清单 host 正则：" + rule.playlistHostRegex.joined(separator: "、")
        }
        return "清单 host：（未限定）"
    }
}
