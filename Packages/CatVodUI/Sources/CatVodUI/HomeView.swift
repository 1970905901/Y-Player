import CatVodCore
import CatVodSource
import SwiftUI

/// 首页：选择站点 → 分类/筛选 → 内容列表 → 进入详情。
///
/// 站点来源：CMS（`type 0/1/2/4`）与 CatSpider HTTP（`type 3`，js2p 宿主）都能浏览，
/// 由 `AppModel.makeSiteClient()` 按类型分发；JS 源的站点清单来自内嵌 Node 宿主（macOS 进程 / iOS libnode，见 M16P4）。
/// 数据加载逻辑见 `HomeView+Data.swift`。
@MainActor
public struct HomeView: View {
    @ObservedObject var model: AppModel
    @State var selectedSiteKey = ""
    /// 当前分类。**程序内回写它不会发起加载**：分类加载的唯一入口是 `categoryBinding`
    /// （见 `HomeView+Data.swift`），否则 `loadHome()` / `loadCategory()` 的回写会再触发一次同页请求。
    @State var selectedCategoryID = ""
    @State var extend: [String: String] = [:]
    @State var result = SpiderResult()
    @State var page = 1
    @State var isLoading = false
    @State var errorText = ""
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

    public var body: some View {
        List {
            if browsableSites.isEmpty {
                Section("首页") {
                    Text(emptyHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                siteSection
                categorySection
                if !filters.isEmpty {
                    filterSection
                }
                contentSection
                pagingSection
            }
            if !errorText.isEmpty {
                Section("错误") {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle("发现")
        .adaptiveToolbar {
            NavigationLink {
                SearchView(model: model)
            } label: {
                Image(systemName: "magnifyingglass")
            }
        } trailing: {
            Button {
                Task { await loadHome(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading || selectedSite == nil)
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

    // MARK: - 区块

    private var siteSection: some View {
        Section("站点") {
            Picker("当前站点", selection: $selectedSiteKey) {
                ForEach(browsableSites) { site in
                    Text(site.name.isEmpty ? site.key : site.name).tag(site.key)
                }
            }
        }
    }

    private var categorySection: some View {
        Section("分类") {
            if result.categories.isEmpty {
                Text(isLoading ? "加载中…" : "暂无分类")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("分类", selection: categoryBinding) {
                    ForEach(result.categories) { category in
                        Text(category.typeName).tag(category.typeID)
                    }
                }
            }
        }
    }

    private var filterSection: some View {
        Section("筛选") {
            ForEach(filters) { filter in
                Picker(filter.name, selection: binding(for: filter)) {
                    ForEach(filter.values) { value in
                        Text(value.name.isEmpty ? value.value : value.name).tag(value.value)
                    }
                }
            }
            Button("应用筛选") {
                page = 1
                Task { await loadCategory() }
            }
        }
    }

    private var contentSection: some View {
        Section("内容") {
            if result.list.isEmpty {
                Text(isLoading ? "加载中…" : "暂无内容")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // 展示方式来自「设置 → 首页 → 展示方式」（`AppModel.homeLayout`）：
            // 纵向是一列内容行（默认，等同 M2 的观感），横向是海报网格。
            // 两种布局都用同一份 `result.list`，分类 / 筛选 / 分页逻辑完全不变。
            switch model.homeLayout {
            case .vertical:
                verticalList
            case .horizontal:
                posterGrid
            }
        }
    }

    private var verticalList: some View {
        ForEach(result.list) { item in
            NavigationLink {
                VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
            } label: {
                VodRow(item: item)
            }
        }
    }

    /// 横向展示：每行固定 ``posterColumnCount`` 张海报卡片（末行由 `posterRows` 补空位）。
    ///
    /// 不用 `LazyVGrid`：它嵌在 `List` 行里的布局行为在各系统版本上并不一致，
    /// 这里用最朴素的 `HStack`（观感与交互仍交给系统控件），换行由 `posterRows` 切好。
    private var posterGrid: some View {
        ForEach(Array(posterRows.enumerated()), id: \.offset) { _, row in
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                    if let item {
                        NavigationLink {
                            VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
                        } label: {
                            PosterCard(item: item)
                        }
                    } else {
                        // 空位：只占宽度，撑住这一行的排版。
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var pagingSection: some View {
        Section {
            HStack {
                Button("上一页") {
                    page = max(page - 1, 1)
                    Task { await loadCategory() }
                }
                .disabled(page <= 1 || isLoading)

                Spacer()
                Text(pageText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()

                Button("下一页") {
                    page += 1
                    Task { await loadCategory() }
                }
                .disabled(isLoading || (result.pagecount > 0 && page >= result.pagecount))
            }
        }
    }

    private var pageText: String {
        result.pagecount > 0 ? "第 \(page) / \(result.pagecount) 页" : "第 \(page) 页"
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
