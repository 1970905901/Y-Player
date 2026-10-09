import CatVodCore
import CatVodSource
import SwiftUI

/// 聚合搜索海报墙（M11 片 5，参考图 f03）：左栏「站点 + 命中数」，右栏竖幅海报网格。
///
/// 入口是详情页图标行的 🔍 —— 搜的就是**这部片的片名**，所以本页没有搜索框：
/// 要换关键词回搜索页，那是搜索页的活；这面墙只回答「别的站点上搜得到什么、长什么样」。
///
/// 搜哪些站点、结果怎么归位见 ``AggregateSearchRules``；请求与并发在
/// `AppModel.searchAcrossSites(keyword:)` 里 —— 本视图只画。
@MainActor
struct AggregateSearchView: View {
    @ObservedObject var model: AppModel
    /// 要搜的片名（详情页带过来的）。
    let keyword: String

    /// 左栏宽度（参考图里左栏约三分之一屏）：要放得下「盘搜|4K 44」这种「名字 + 命中数」。
    static let sidebarWidth: CGFloat = 132

    @State private var sections: [AggregateSearchSection] = []
    /// 选中的站点；nil = 「全部」。
    @State private var selectedSiteKey: String?
    @State private var isLoading = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            resultPane
        }
        .navigationTitle(keyword)
        .adaptiveInlineNavigationTitle()
        // 详情 → 海报墙这一路都不该出现底部 Tab 栏（登记机制见 Platform/AdaptiveTabBar.swift）。
        .immersiveTabBarPage()
        .task { await load() }
    }

    // MARK: - 左栏

    /// 左栏：站点清单（只列有命中的站点）+ 命中数；「全部」在最上面。
    ///
    /// 还在搜的时候一条都不画：「全部 0」看着像搜完了没结果，不如把话留给右栏的加载态。
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !sections.isEmpty {
                    row(name: "全部", count: totalCount, key: nil)
                    ForEach(sections) { section in
                        row(name: section.siteName, count: section.count, key: section.site.key)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .frame(width: Self.sidebarWidth, alignment: .top)
        .background(Color.secondary.opacity(0.08))
    }

    /// 左栏的一行：名字（自动截断）+ 命中数；选中的那一行高亮。
    private func row(name: String, count: Int, key: String?) -> some View {
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
                Text("\(count)")
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
                placeholder(emptyHint, showsSpinner: false)
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

    private func placeholder(_ text: String, showsSpinner: Bool) -> some View {
        VStack(spacing: 8) {
            if showsSpinner {
                ProgressView()
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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

    private var totalCount: Int {
        sections.reduce(0) { $0 + $1.count }
    }

    private var emptyHint: String {
        if model.sites.isEmpty {
            return "还没有可用站点：请先在「设置 → 源地址」里加载配置。"
        }
        return "各站点都没有搜到「\(keyword)」。"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        sections = await model.searchAcrossSites(keyword: keyword)
        // 选中的站点这一轮没命中（或站点清单变过）：回落「全部」，别停在一张空网格上。
        if let key = selectedSiteKey, !sections.contains(where: { $0.id == key }) {
            selectedSiteKey = nil
        }
    }

    /// 右栏的一格：条目 + 它属于哪个站点（点进详情要用站点）。
    private struct WallEntry: Identifiable {
        let site: Site
        let item: VodItem

        var id: String { site.key + "|" + item.vodID }
    }
}
