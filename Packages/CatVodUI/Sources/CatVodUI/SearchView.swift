import CatVodCore
import CatVodSource
import SwiftUI

/// 搜索页：站点 → 关键词 → 结果 → 详情。
///
/// 版式对齐用户提供的参考录屏（`RPReplay_Final1791437934` 后半段，配套截图 `IMG_7327`）：
/// 导航栏里是**返回箭头 + 搜索框（占位「请输入影片名称」）+ 圆形按钮**（三者同一行），
/// 圆形按钮点开就是**站点面板**（与发现页左上角同一个面板）；下方是「搜索历史」标题 + 🗑 清空
/// + 历史胶囊；搜索结果是 3 列海报网格，滚动到底自动续页（没有分页按钮）。
///
/// 站点来源：CMS 与 CatSpider HTTP（js2p 宿主）都能搜，由 `AppModel.makeSiteClient()` 分发；
/// 数据加载逻辑见 `SearchView+Data.swift`，历史规则见 `SearchHistory.swift`。
@MainActor
public struct SearchView: View {
    @ObservedObject var model: AppModel
    @State var selectedSiteKey = ""
    @State var keyword = ""
    @State var submittedKeyword = ""
    @State var result = SpiderResult()
    @State var page = 1
    @State var isLoading = false
    @State var errorText = ""
    /// 上一次翻页拿到了空列表：上游没给 `pagecount` 时靠它停住「上拉加载」。
    @State var reachedEnd = false
    /// 站点面板是否展开（参考截图：点搜索框右侧的圆形按钮弹出）。
    @State var isSitePanelPresented = false

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

    public var body: some View {
        ZStack(alignment: .topLeading) {
            content
            if isSitePanelPresented {
                sitePanelOverlay
                    .transition(.opacity)
            }
        }
        .navigationTitle("搜索")
        .adaptiveInlineNavigationTitle()
        .adaptiveSearchBar(text: $keyword, prompt: "请输入影片名称") {
            siteSwitcherButton
        }
        .onSubmit {
            Task { await startSearch() }
        }
        .task {
            // 选择还原：当前（还在）> 上次保存的（还在）> 首个。搜索页每次 push 都是新实例，
            // 不还原的话「切站点 → 返回 → 再进搜索」就丢了选择（规则与发现页共用 `SiteSelection`）。
            selectedSiteKey = SiteSelection.resolvedKey(
                current: selectedSiteKey,
                saved: model.searchSiteKey,
                available: browsableSites.map(\.key)
            )
        }
        .onChange(of: selectedSiteKey) { _ in
            // 换站点后落盘 + 清空上次结果：不能把别的站点的结果显示成本站点的结果。
            model.searchSiteKey = selectedSiteKey
            clearResults()
        }
        .onChange(of: model.siteCatalogRevision) { _ in
            // 接口换了（搜索页常驻在首页 Tab 的导航栈里，`.task` 不会重跑）：旧站点与旧结果全部作废，
            // 否则搜索会继续对着上一个接口的站点发请求。
            clearResults()
            selectedSiteKey = SiteSelection.resolvedKey(
                current: selectedSiteKey,
                saved: model.searchSiteKey,
                available: browsableSites.map(\.key)
            )
        }
    }

    // MARK: - 主体

    @ViewBuilder private var content: some View {
        if browsableSites.isEmpty {
            placeholder(emptyHint)
        } else if result.list.isEmpty, submittedKeyword.isEmpty {
            historySection
        } else {
            resultsScroll
        }
    }

    // MARK: - 结果区

    /// 结果区：可滚动的内容 + 底部「加载中… / 没有更多了」。
    private var resultsScroll: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if !errorText.isEmpty {
                    errorBanner
                }
                if result.list.isEmpty {
                    placeholder(isLoading ? "搜索中…" : "没有找到与「\(submittedKeyword)」相关的内容。")
                } else {
                    posterGrid
                }
                loadMoreFooter
            }
            .padding(.vertical, 8)
        }
    }

    /// 搜索结果：3 列海报网格（与发现页同一套卡片与列数约定）。
    private var posterGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: HomeView.posterColumnCount),
            spacing: 16
        ) {
            ForEach(result.list) { item in
                NavigationLink {
                    VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
                } label: {
                    DiscoverPosterCard(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

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
            // `id` 用「页码 + 条数」：追加完成、或上次因正在加载被跳过时都能接着取下一页。
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

    // MARK: - 搜索历史

    /// 还没搜索时的页面：标题「搜索历史」+ 清空按钮 + 历史胶囊（参考录屏的未搜索态）。
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("搜索历史")
                    .font(.headline)
                Spacer()
                if !model.searchHistory.isEmpty {
                    Button {
                        model.clearSearchHistory()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索历史")
                }
            }

            if model.searchHistory.isEmpty {
                Text("还没有搜索记录：点上面的搜索框输入片名，回车即可搜索。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // 自适应列宽的网格：不用手写换行逻辑（iOS 15 没有 `Layout` 协议，
                // 做不了「宽度撑开就换行」的流式布局）。
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 76), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(model.searchHistory, id: \.self) { term in
                        Button {
                            keyword = term
                            Task { await startSearch() }
                        } label: {
                            Text(term)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 工具栏与站点面板

    /// 搜索框右侧的圆形按钮：点开站点面板（参考截图里的入口）。
    ///
    /// 字形按录屏放大后的样子取：圆圈 + 三条递减横线（SF Symbols 里有对应项）。
    private var siteSwitcherButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isSitePanelPresented.toggle()
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .disabled(browsableSites.isEmpty)
        .accessibilityLabel("切换站点")
    }

    /// 站点面板：与发现页左上角**同一个面板**；这里贴左悬浮 + 透明点击层收起。
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
                    // 清空动作交给 `.onChange(of: selectedSiteKey)`，避免两处都改状态。
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

    // MARK: - 空态 / 错误

    /// 空态 / 加载态：居中一行（加载中时带系统指示器）。
    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView()
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 16)
    }

    private var errorBanner: some View {
        Text(errorText)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// 无可用站点时的说明（区分「接口加载失败」「没配置」「JS 源宿主状态」「没有可搜索站点」）。
    private var emptyHint: String {
        if let reason = model.state.failureReason {
            // 接口加载失败（含冷启动自动恢复失败）：直接说原因，别显示「请先加载配置」。
            return "接口加载失败：\(reason)"
        }
        if model.allSites.isEmpty {
            return "还没有可用站点：请先在「设置 → 源地址」里加载配置。"
        }
        if model.loadedKind == .javaScript {
            return model.hostStatus.summary
        }
        return "当前没有支持搜索的站点。"
    }
}
