import CatVodCore
import CatVodSource
import SwiftUI

/// 发现页：选站点 → 分类 / 筛选 → 内容 → 进入详情。
///
/// 版式对齐用户提供的两张参考图（`发现页横向显示.jpg` / `发现页纵向显示.jpg`）：
/// **横向展示**＝按分类分区、每区一行横滑（图 1）；**纵向展示**＝分类 + 筛选 + 3 列网格（图 2）。
/// 两种模式的对应关系与历史坑见 ``HomeLayout`` 的注释 —— 注意别按名字猜。
/// 左上角是**站点切换**（「切换」字形 + 当前站点名，点开贴左的站点面板；⚠️ 站点名里的
/// 「☁️」是上游名字自带的表情，不是按钮图标），右上角是刷新与搜索；下面依次是横向滚动的分类条、
/// 逐行筛选胶囊，内容是 3 列海报网格（封面右上角带更新角标、片名居中一行），
/// 滚动到底部**自动接着加载**下一页（参考版式里没有分页按钮）。
/// 分类条 / 筛选胶囊 / 网格同处**一个滚动区**：上滑时连在一起滚出屏幕（整屏滑动）。
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
    /// 站点切换面板是否展开（参考视频：点左上角的「切换」按钮弹出）。
    @State var isSitePanelPresented = false
    /// 已加载内容对应的「站点清单版本」（`AppModel.siteCatalogRevision`）。
    ///
    /// 与 `selectedSiteKey` 一起构成「这份内容属于哪个接口」的判断：
    /// 版本对不上就说明接口换过（或宿主刷新过），旧站点/分类/筛选/列表全部作废。
    @State var loadedCatalogRevision = -1
    /// 横向展示的分区数据（每个分类一页）。只在这个模式下加载，见 `posterSections`。
    @State var sections: [DiscoverSection] = []
    @State var isLoadingSections = false
    /// 底部 Tab 栏的收放（规格与判定见 ``DiscoverTabBarVisibility``）。
    @State private var tabBar = DiscoverTabBarVisibility()
    /// 本 Tab 的沉浸页登记簿（详情 / 播放压上来时也要收栏）；登记方见 ``ImmersiveTabBarPageModifier``。
    @EnvironmentObject private var immersiveTabBar: ImmersiveTabBarState
    /// 网页条目（如宿主配置中心）要在 App 内打开的地址；nil = 没开。
    @State private var webEntry: WebEntry?

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
        return model.siteDisplayName(for: site)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            content
            if isSitePanelPresented {
                sitePanelOverlay
                    .transition(.opacity)
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
            // 顺手落盘：冷启动 / 去别的 Tab 回来时据此还原（见 `syncHomeWithInterface`）。
            model.discoverSiteKey = selectedSiteKey
            invalidateContent()
            Task { await loadHome(force: true) }
        }
        .sheet(item: $webEntry) { entry in
            // 配置中心这类「网页条目」：App 内打开（见 `WebEntryRules` / `WebPageSheet`）。
            WebPageSheet(entry: entry)
        }
        .adaptiveTabBarHidden(tabBar.isHidden || immersiveTabBar.isActive)
        .onDisappear {
            // 离开发现页把 Tab 栏放回来：它是导航出去的路，不能带着收起状态离开。
            tabBar.reveal()
        }
    }

    // MARK: - 主体

    private var content: some View {
        VStack(spacing: 0) {
            if browsableSites.isEmpty {
                placeholder(emptyHint)
            } else {
                contentScroll
            }
            if !errorText.isEmpty {
                errorBanner
            }
        }
    }

    /// 内容区：横向展示是 3 列海报网格（参考视频的版式），纵向展示是内容行（M2 的原观感）。
    /// 两种展示方式共用同一份数据与同一条翻页路径，只有排布不同。
    ///
    /// 分类条 / 筛选行 / 列表**同处一个滚动区**：上滑时三块一起滚出屏幕（整屏滑动，
    /// 「封面列表和分组分类连着」）。
    private var contentScroll: some View {
        ScrollView {
            VStack(spacing: 0) {
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
                contentBody
            }
        }
        // 「手指碰到屏幕」和「向上滑」是两个不同信号，各挂一个**旁听**手势：
        // 前者用零时长长按（成功即触屏），后者用零距离拖动（读位移方向）。
        // 都走 `simultaneousGesture`：滚动本身一行没改，它们只旁听 —— 换成 `.gesture` 会抢走滚动。
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0, maximumDistance: .infinity)
                .onEnded { _ in
                    tabBar.touchDown()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    tabBar.dragChanged(
                        translationX: value.translation.width,
                        translationY: value.translation.height
                    )
                }
                .onEnded { _ in
                    tabBar.touchEnded()
                }
        )
    }

    @ViewBuilder private var contentBody: some View {
        if result.list.isEmpty {
            placeholder(isLoading ? "加载中…" : "暂无内容")
        } else {
            switch model.homeLayout {
            case .vertical:
                posterGrid
            case .horizontal:
                posterSections
            }
            loadMoreFooter
        }
    }

    /// 横向展示：每个分类一个分区（标题 + `>` + 一行横滑海报），对齐参考图 1。
    ///
    /// 数据只在这个模式加载（`.task` 挂在 `ScrollView` 上）：纵向模式不需要它，
    /// 而它要为每个分区各发一次请求 —— 没必要让只切进来一次的布局也付这份开销。
    private var posterSections: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        DiscoverSectionHeader(title: section.title) {
                            openSection(section)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(section.items) { item in
                                    posterLink(item) {
                                        DiscoverPosterCard(item: item)
                                            .frame(width: Self.sectionCardWidth)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                if sections.isEmpty {
                    placeholder(isLoadingSections ? "加载中…" : "暂无内容")
                }
            }
            .padding(.vertical, 12)
        }
        .task(id: sectionLoadKey) {
            // 站点或接口版本变了：旧分区作废（key 变了 `.task` 会重跑）。
            sections = []
            await loadSections()
        }
    }

    /// 分区数据的「属于哪个接口」标识。
    ///
    /// 与 `loadedCatalogRevision` 同一套思路：单靠站点 key 不够 —— js2p 宿主刷新后站点 key 不变、
    /// 内容却全换了，所以把 `siteCatalogRevision` 也带上。
    private var sectionLoadKey: String {
        "\(selectedSiteKey)#\(model.siteCatalogRevision)"
    }

    /// 分区标题上的 `>`：选中这个分类并切到纵向展示（那个分类的完整列表就是纵向模式）。
    private func openSection(_ section: DiscoverSection) {
        selectCategory(section.id)
        model.homeLayout = .vertical
    }

    /// 分区里每张海报的宽度：参考图 1 里一屏约看到三张半。
    static let sectionCardWidth: CGFloat = 112

    /// 横向展示最多取几个分区：接口常有十来个分类，全取等于首屏发十几次请求。
    /// 参考图第一屏可见的就是三四个分区，所以截前几个。
    static let sectionCategoryLimit = 5

    private var posterGrid: some View {
        LazyVGrid(columns: posterColumns, spacing: 14) {
            ForEach(result.list) { item in
                posterLink(item) {
                    DiscoverPosterCard(item: item)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 一张海报卡的点击行为：普通条目进详情；**网页条目**（配置中心这类）开着网页看
    /// —— 详情接口里没有它的内容，进去只会是一片空白（见 ``WebEntryRules``）。
    @ViewBuilder
    private func posterLink<Label: View>(
        _ item: VodItem,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let url = WebEntryRules.webURL(for: item, site: selectedSite) {
            Button {
                webEntry = WebEntry(url: url)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        }
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

    /// 左上角：站点切换入口 —— 「切换」字形 + 当前站点名（参考录屏的形态）。
    ///
    /// 录屏里这个位置**没有下拉箭头**：图标本身（两个开关）就表示「点这里换站点」。
    private var siteSwitcherButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isSitePanelPresented.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                DiscoverSiteSwitchGlyph()
                Text(siteTitle)
                    .lineLimit(1)
            }
            .font(.body.weight(.semibold))
        }
        .disabled(browsableSites.isEmpty)
    }

    /// 右上角：刷新（回到第一页并绕过缓存）与搜索。
    ///
    /// 直播入口**不在这里**：它已经是底部 Tab 的「直播」（M07c-6 从纸飞机按钮改过去，
    /// 理由与取舍见 `docs/任务记录/M07c6-直播入口改底部Tab.md`）。
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

    /// 站点面板：贴左的悬浮卡片 + 一层**透明**点击层。
    ///
    /// 录屏里面板外的内容没有变暗，所以这里用透明点击层而不是黑色遮罩：
    /// 点面板外收起，点面板本体不会穿透（面板在 `ZStack` 里排在点击层之后）。
    private var sitePanelOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { dismissSitePanel() }
                DiscoverSitePanel(
                    sites: browsableSites,
                    selectedKey: selectedSiteKey,
                    ruleInput: model.siteRuleInput,
                    savedGroupOrder: model.siteGroupOrder,
                    onMoveGroup: { group, direction in
                        model.moveSiteGroup(group, direction: direction)
                    },
                    onRename: { key, name in
                        if let site = browsableSites.first(where: { $0.key == key }) {
                            model.renameSite(site, to: name)
                        }
                    }
                ) { key in
                    dismissSitePanel()
                    // 加载交给 `.onChange(of: selectedSiteKey)` 统一发起，避免同一次切换发两次请求。
                    selectedSiteKey = key
                }
                .frame(
                    width: proxy.size.width * DiscoverSitePanel.widthFraction,
                    height: proxy.size.height * DiscoverSitePanel.heightFraction
                )
                .padding(.leading, 12)
                .padding(.top, 6)
            }
        }
    }

    private func dismissSitePanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isSitePanelPresented = false
        }
    }

    private var emptyHint: String {
        if let reason = model.state.failureReason {
            // 接口加载失败（含冷启动自动恢复失败）：直接说原因，
            // 不要显示「请先在接口管理里加载配置」——用户明明已经配置过接口。
            return "接口加载失败：\(reason)"
        }
        if model.allSites.isEmpty {
            // 多仓配置（`urls`）：站点本来就是空的 —— 说清「要自己挑一条子配置」，
            // 否则用户看到的就是「还没有可用站点」，只会以为配置没生效（M18P1）。
            if !model.configSubURLEntries.isEmpty {
                return "这份配置是多配置入口（`urls`，共 \(model.configSubURLEntries.count) 条）："
                    + "去「设置 → 源地址 → 多配置入口」点一条加载。"
            }
            if !model.liveSources.isEmpty {
                // 只有直播源的配置：点播确实没内容，但直播能用 —— 别让用户以为配置坏了。
                return "这份配置只有直播源：去底部「直播」Tab 看。"
            }
            return "还没有可用站点：请先在「设置 → 源地址」里加载配置。"
        }
        if model.loadedKind == .javaScript {
            // JS 源的站点来自内嵌 Node 宿主：把真实状态显示出来，而不是「等 M1.6」的占位文案。
            return model.hostStatus.summary
        }
        return "当前没有可用站点。"
    }
}
