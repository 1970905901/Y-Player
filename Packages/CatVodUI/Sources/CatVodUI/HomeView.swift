import CatVodCore
import CatVodSource
import SwiftUI

/// 发现页：选站点 → 分类 / 筛选 → 内容 → 进入详情。
///
/// 版式对齐用户提供的参考录屏（`RPReplay_Final1791437934`）：
/// 左上角站点名点开是站点切换面板，右上角是刷新与搜索；下面依次是横向滚动的分类条、
/// 逐行筛选胶囊，内容是 3 列海报网格（封面右上角带更新角标、片名居中一行），
/// 滚动到底部**自动接着加载**下一页（参考版式里没有分页按钮）。
///
/// 站点来源：CMS（`type 0/1/2/4`）与 CatSpider HTTP（`type 3`，js2p 宿主）都能浏览，
/// 由 `AppModel.makeSiteClient()` 按类型分发；JS 源的站点清单来自内嵌 Node 宿主（macOS 进程 / iOS libnode，见 M16P4）。
/// 数据加载逻辑见 `HomeView+Data.swift`，判定逻辑见 `DiscoverLayout.swift`，展示件见 `DiscoverViews.swift`。
@MainActor
public struct HomeView: View {
    @ObservedObject var model: AppModel
    @State var selectedSiteKey = ""
    /// 当前分类。**程序内回写它不会发起加载**：分类加载的唯一入口是 `selectCategory(_:)`
    /// （见 `HomeView+Data.swift`），否则 `loadHome()` / `loadCategory()` 的回写会再触发一次同页请求。
    @State var selectedCategoryID = ""
    @State var extend: [String: String] = [:]
    @State var result = SpiderResult()
    @State var page = 1
    @State var isLoading = false
    @State var errorText = ""
    /// 上一次翻页拿到了空列表：上游没给 `pagecount` 时靠它停住「上拉加载」。
    @State var reachedEnd = false
    /// 站点切换面板是否展开（参考视频：点左上角站点名弹出）。
    @State var isSitePanelPresented = false
    /// 已加载内容对应的「站点清单版本」（`AppModel.siteCatalogRevision`）。
    ///
    /// 与 `selectedSiteKey` 一起构成「这份内容属于哪个接口」的判断：
    /// 版本对不上就说明接口换过（或宿主刷新过），旧站点/分类/筛选/列表全部作废。
    @State var loadedCatalogRevision = -1

    public init(model: AppModel) {
        self.model = model
    }

    /// 可浏览的站点。
    ///
    /// 同时包含 CMS（`type 0/1/2/4`）与 CatSpider HTTP（`type 3`，js2p 宿主站点）：
    /// 两者都由 `AppModel.makeSiteClient()` 按类型分发，界面不再需要自己区分。
    var browsableSites: [Site] {
        model.sites
    }

    var selectedSite: Site? {
        browsableSites.first { $0.key == selectedSiteKey } ?? browsableSites.first
    }

    var selectedCategory: VodCategory? {
        result.categories.first { $0.typeID == selectedCategoryID } ?? result.categories.first
    }

    var filters: [VodFilter] {
        guard let category = selectedCategory else {
            return []
        }
        return result.filters[category.typeID] ?? category.filters
    }

    /// 筛选区的回显模型（上游没给筛选名的行不占左侧标签位，与参考视频一致）。
    var filterRows: [DiscoverFilterRow] {
        DiscoverFilterRow.rows(filters: filters, selected: extend)
    }

    /// 站点按钮上的名字（站点名为空时回落 `key`）。
    var siteTitle: String {
        guard let site = selectedSite else {
            return "选择站点"
        }
        return site.name.isEmpty ? site.key : site.name
    }

    public var body: some View {
        ZStack(alignment: .top) {
            content
            if isSitePanelPresented {
                sitePanelOverlay
            }
        }
        .navigationTitle("发现")
        .adaptiveInlineNavigationTitle()
        .adaptiveToolbar {
            siteSwitcherButton
        } trailing: {
            trailingButtons
        }
        .task {
            await syncHomeWithInterface()
        }
        .onChange(of: model.siteCatalogRevision) { _ in
            // 接口换了（加载新配置 / 宿主刷新 / 宿主停止）：首页必须自己重来一遍。
            // 不能指望 `.task`：TabView 里的首页是常驻视图，`.task` 在回到该 Tab 时不一定重跑，
            // 而且它重跑时 `loadHome()` 也会因为已有分类直接返回（这正是「必须冷启动」的原因）。
            // 这里用非结构化 `Task` 而不是 `.task`：离开首页 Tab 时这次重载不该被取消。
            Task { await syncHomeWithInterface() }
        }
        .onChange(of: selectedSiteKey) { _ in
            // 站点换了：旧站点的分类/筛选/列表全部作废（否则会出现「站点已换、内容还是旧的」）。
            invalidateContent()
            Task { await loadHome(force: true) }
        }
    }

    // MARK: - 主体

    private var content: some View {
        VStack(spacing: 0) {
            if browsableSites.isEmpty {
                placeholder(emptyHint)
            } else {
                if !result.categories.isEmpty {
                    DiscoverCategoryStrip(
                        categories: result.categories,
                        selectedID: selectedCategory?.typeID ?? "",
                        onSelect: selectCategory
                    )
                }
                if !filterRows.isEmpty {
                    DiscoverFilterStrip(rows: filterRows) { row, value in
                        applyFilter(row, value: value)
                    }
                }
                contentScroll
            }
            if !errorText.isEmpty {
                errorBanner
            }
        }
    }

    /// 内容区：横向展示是 3 列海报网格（参考视频的版式），纵向展示是内容行（M2 的原观感）。
    /// 两种展示方式共用同一份数据与同一条翻页路径，只有排布不同。
    private var contentScroll: some View {
        ScrollView {
            contentBody
        }
    }

    @ViewBuilder private var contentBody: some View {
        if result.list.isEmpty {
            placeholder(isLoading ? "加载中…" : "暂无内容")
        } else {
            switch model.homeLayout {
            case .vertical:
                verticalList
            case .horizontal:
                posterGrid
            }
            loadMoreFooter
        }
    }

    private var verticalList: some View {
        LazyVStack(spacing: 12) {
            ForEach(result.list) { item in
                NavigationLink {
                    VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
                } label: {
                    VodRow(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var posterGrid: some View {
        LazyVGrid(columns: posterColumns, spacing: 14) {
            ForEach(result.list) { item in
                NavigationLink {
                    VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
                } label: {
                    DiscoverPosterCard(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var posterColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
            count: Self.posterColumnCount
        )
    }

    // MARK: - 底部与状态

    /// 底部：还能翻页就显示「加载中…」并触发下一页（参考版式里没有分页按钮）。
    @ViewBuilder private var loadMoreFooter: some View {
        if canLoadMore {
            HStack(spacing: 8) {
                ProgressView()
                Text("加载中…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            // `id` 用「页码 + 条数」：任一变化都会重新触发 —— 上一页追加完成、或上次因
            // 正在加载被跳过时，都能接着把下一页取回来。
            .task(id: loadMoreTrigger) {
                await loadMore()
            }
        } else if !result.list.isEmpty {
            Text("没有更多了")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    /// 空态 / 加载态：居中一行（加载中时带系统指示器，与参考视频一致）。
    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView()
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var errorBanner: some View {
        Text(errorText)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    // MARK: - 工具栏

    /// 左上角：站点名 + 下拉箭头，点开站点切换面板（参考视频的入口）。
    private var siteSwitcherButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isSitePanelPresented.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cloud")
                Text(siteTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.body.weight(.semibold))
        }
        .disabled(browsableSites.isEmpty)
    }

    /// 右上角：刷新（回到第一页并绕过缓存）与搜索。
    private var trailingButtons: some View {
        HStack(spacing: 16) {
            Button {
                // 上拉加载可能已经翻到很后面，所以刷新一律回到第一页。
                page = 1
                reachedEnd = false
                Task { await loadHome(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading || selectedSite == nil)

            NavigationLink {
                SearchView(model: model)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(browsableSites.isEmpty)
        }
    }

    // MARK: - 站点切换面板

    private var sitePanelOverlay: some View {
        ZStack(alignment: .top) {
            // 半透明遮罩：点一下收起面板（参考视频的弹出层行为）。
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSitePanelPresented = false
                    }
                }
            DiscoverSitePanel(sites: browsableSites, selectedKey: selectedSiteKey) { key in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isSitePanelPresented = false
                }
                // 加载交给 `.onChange(of: selectedSiteKey)` 统一发起，避免同一次切换发两次请求。
                selectedSiteKey = key
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var emptyHint: String {
        if let reason = model.state.failureReason {
            // 接口加载失败（含冷启动自动恢复失败）：直接说原因，
            // 不要显示「请先在接口管理里加载配置」——用户明明已经配置过接口。
            return "接口加载失败：\(reason)"
        }
        if model.allSites.isEmpty {
            return "还没有可用站点：请先在「设置 → 源地址」里加载配置。"
        }
        if model.loadedKind == .javaScript {
            // JS 源的站点来自内嵌 Node 宿主：把真实状态显示出来，而不是「等 M1.6」的占位文案。
            return model.hostStatus.summary
        }
        return "当前没有可用站点。"
    }
}
