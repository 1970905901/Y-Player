import CatVodCore
import CatVodSource
import SwiftUI

/// 「筛选站源」按钮：搜索栏 / 海报墙右上角那个圆圈（参考图一里的入口）。
///
/// 抽出来是因为有两个调用点（搜索页的搜索框、详情页 🔍 墙的导航栏），
/// 图标与无障碍标签必须一模一样 —— 两处各写一遍迟早会飘。
@MainActor
struct SearchSourceFilterButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("筛选站源")
    }
}

/// 「筛选站源」面板（M11 参考图二）：一个站点一行、一个开关，决定**聚合搜索**搜哪些站点。
///
/// 三条约定：
/// 1. **两个入口共用**：搜索页与详情页 🔍 的海报墙都读 `AppModel.searchEnabledSites`；
/// 2. **✓ 才生效、✕ 是放弃**：面板里改的是一份本地副本，点 ✓ 写回并触发重搜
///    （否则每拨一个开关就发一轮请求）；✕ 原样退出 —— 这也是参考图上那两个按钮的语义；
/// 3. 平台跑不了 / 配置里关了搜索的站点：开关**置灰并写明原因**，不做「点了没反应」的假开关。
@MainActor
struct SearchSourceFilterView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 本地副本（`key` = 被关掉的站点）。
    @State private var excluded: Set<String>

    init(model: AppModel) {
        self.model = model
        _excluded = State(initialValue: model.searchExcludedSiteKeys)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                if model.allSites.isEmpty {
                    Text("还没有可用站点：请先在「设置 → 源地址」里加载配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.allSites) { site in
                    row(site)
                }
            }
            .adaptiveListStyle()
        }
    }

    // MARK: - 头部

    /// ✕（放弃）/ 标题 / ✓（应用）—— 参考图二的形态。
    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("关闭（不保存）")
            Spacer()
            Text("筛选站源")
                .font(.headline)
            Spacer()
            Button {
                model.searchExcludedSiteKeys = excluded
                dismiss()
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("应用")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 一行

    private func row(_ site: Site) -> some View {
        let disabledReason = AggregateSearchRules.searchDisabledReason(site)
        return Toggle(isOn: binding(site)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.siteDisplayName(for: site))
                if let disabledReason {
                    Text(disabledReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(disabledReason != nil)
    }

    /// 面板里那一行的开关：读写的都是**本地副本**，点 ✓ 才落到 model 上。
    private func binding(_ site: Site) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(site.key) },
            set: { isOn in
                if isOn {
                    excluded.remove(site.key)
                } else {
                    excluded.insert(site.key)
                }
            }
        )
    }
}
