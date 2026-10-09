import CatVodCore
import CatVodSource
import SwiftUI

/// 聚合搜索的「墙面」（M11 片 5，参考图一）：左栏「站点 + 命中数」，右栏竖幅海报网格。
///
/// 两个入口共用同一面墙：
/// - **搜索页**（关键词来自搜索框）；
/// - **详情页图标行的 🔍**（关键词 = 这部片的片名）。
/// 站点范围由 `AppModel.searchEnabledSites` 决定（含「筛选站源」的开关），本视图只画。
@MainActor
struct AggregateSearchWall: View {
    @ObservedObject var model: AppModel
    /// 搜什么。
    let keyword: String
    /// 重新提交的计数：同一个关键词再搜一次也要重跑（搜索页每次提交 +1）。
    let revision: Int

    /// 左栏宽度（参考图里左栏约三分之一屏）：要放得下「盘搜|4K 44」这种「名字 + 命中数」。
    static let sidebarWidth: CGFloat = 132

    @State private var sections: [AggregateSearchSection] = []
    /// 选中的站点；nil = 「全部」。
    @State private var selectedSiteKey: String?
    @State private var isLoading = true
    /// 这一轮实际搜了几个站点（左栏「全部」那一行与空态都要用）。
    @State private var searchedCount = 0
    /// 失败站点的可读原因（`站点名：原因`）。
    @State private var failures: [String] = []
    /// 首轮（索引站点）零命中后是否补搜了其余可搜站点（空态据此把话说全）。
    @State private var didFallBackToAllSites = false
    /// 发起过多少轮搜索：只认最后发起的那一轮（见 ``load()`` 里的竞态说明）。
    @State private var loadGeneration = 0

    init(model: AppModel, keyword: String, revision: Int = 0) {
        self.model = model
        self.keyword = keyword
        self.revision = revision
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            resultPane
        }
        .task(id: reloadKey) { await load() }
    }

    /// 重搜条件：关键词、重新提交的计数，或「筛选站源」的开关组合变了。
    ///
    /// 用分隔符拼集合：`Set` 本身没顺序，直接拼会因顺序抖动反复重搜。
    private var reloadKey: String {
        let excluded = model.searchExcludedSiteKeys.sorted().joined(separator: "\u{1}")
        return "\(keyword)\u{1}\(revision)\u{1}\(excluded)"
    }

    // MARK: - 左栏

    /// 左栏：站点清单（只列有命中的站点）+ 命中数；「全部」在最上面。
    ///
    /// 还在搜的时候一条都不画：「全部 0/0」看着像搜完了没结果，不如把话留给右栏的加载态。
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !sections.isEmpty {
                    // 参考图一的写法：命中站点数 / 参与搜索的站点数。
                    row(name: "全部", trailing: "(\(sections.count)/\(searchedCount))", key: nil)
                    ForEach(sections) { section in
                        row(name: section.siteName, trailing: "\(section.count)", key: section.site.key)
                    }
                }
                if !sections.isEmpty, !failures.isEmpty {
                    // 有结果也要把失败说出来：不然「这个站怎么没上墙」只能靠猜。
                    Text("另有 \(failures.count) 个站点失败")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .frame(width: Self.sidebarWidth, alignment: .top)
        .background(Color.secondary.opacity(0.08))
    }

    /// 左栏的一行：名字（自动截断）+ 右侧的计数；选中的那一行高亮。
    private func row(name: String, trailing: String, key: String?) -> some View {
        let isSelected = selectedSiteKey == key
        return Button {
            selectedSiteKey = key
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右栏

    private var resultPane: some View {
        ScrollView {
            if isLoading {
                placeholder("正在各站点搜索…", showsSpinner: true)
            } else if visibleEntries.isEmpty {
                placeholder(emptyHint, showsSpinner: false, showsRetry: true)
            } else {
                grid
            }
        }
        .refreshable { await load() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 海报网格：右栏宽度只够 2 列（左栏已经吃掉一块），卡片复用发现页/搜索页那张。
    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
            spacing: 16
        ) {
            ForEach(visibleEntries) { entry in
                NavigationLink {
                    VodDetailView(model: model, site: entry.site, vodID: entry.item.vodID)
                } label: {
                    DiscoverPosterCard(item: entry.item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private func placeholder(_ text: String, showsSpinner: Bool, showsRetry: Bool = false) -> some View {
        VStack(spacing: 12) {
            if showsSpinner {
                ProgressView()
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsRetry {
                Button("重试") {
                    Task { await load() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.horizontal, 16)
    }

    // MARK: - 状态

    /// 右栏要画的格子：选中站点就只画那一站；「全部」把各站点摞起来（顺序 = 左栏顺序）。
    ///
    /// 每格都自己带着站点 —— 「全部」那一档里，条目只知道自己，进详情页要靠站点才能定位。
    private var visibleEntries: [WallEntry] {
        if let key = selectedSiteKey, let section = sections.first(where: { $0.id == key }) {
            return section.items.map { WallEntry(site: section.site, item: $0) }
        }
        return sections.flatMap { section in
            section.items.map { WallEntry(site: section.site, item: $0) }
        }
    }

    /// 空态要把「为什么空」说清：**没有参与搜索的站点 / 站点全失败 / 搜到了但零命中**是三件事，
    /// 含糊成一句「没找到」最耽误排查。
    private var emptyHint: String {
        if model.sites.isEmpty {
            return "还没有可用站点：请先在「设置 → 源地址」里加载配置。"
        }
        if searchedCount == 0 {
            return "没有参与搜索的站点：在「筛选站源」里打开几个（站点自己也要能搜：能跑 + 配置没关搜索）。"
        }
        if failures.count >= searchedCount {
            return "\(searchedCount) 个站点都没搜成功：\n" + failures.prefix(3).joined(separator: "\n")
        }
        if didFallBackToAllSites {
            return failures.isEmpty
                ? "索引站点没搜到，「\(keyword)」在其余可搜站点里也没有。"
                : "索引站点没搜到，其余可搜站点也没有；其中 \(failures.count) 个站点搜索失败。"
        }
        if !failures.isEmpty {
            return "各站点都没有搜到「\(keyword)」。\n另有 \(failures.count) 个站点搜索失败。"
        }
        return "各站点都没有搜到「\(keyword)」。"
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        let outcome = await model.searchAcrossSites(keyword: keyword)
        // 搜索途中关键词 / 筛选站源又变了：`.task(id:)` 会取消旧任务，但**旧任务可能已经跑完**，
        // 放任它写回就会用旧结果盖掉新结果。只认最后发起的那一轮。
        guard generation == loadGeneration else {
            return
        }
        sections = outcome.sections
        searchedCount = outcome.searchedCount
        failures = outcome.failures
        didFallBackToAllSites = outcome.didFallBackToAllSites
        // 选中的站点这一轮没命中（或站点清单 / 开关变过）：回落「全部」，别停在一张空网格上。
        if let key = selectedSiteKey, !sections.contains(where: { $0.id == key }) {
            selectedSiteKey = nil
        }
        isLoading = false
    }

    /// 右栏的一格：条目 + 它属于哪个站点（点进详情要用站点）。
    private struct WallEntry: Identifiable {
        let site: Site
        let item: VodItem

        var id: String { site.key + "|" + item.vodID }
    }
}
