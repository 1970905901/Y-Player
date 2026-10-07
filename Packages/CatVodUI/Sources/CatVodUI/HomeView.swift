import CatVodCore
import CatVodSource
import SwiftUI

/// 首页：选择站点 → 分类/筛选 → 内容列表 → 进入详情。
///
/// 范围（M2）：仅处理 CMS 站点（`type 0/1/2/4`）；`type=3` 的 JS/CatSpider 站点需要等 M1.6 的内嵌 Node 服务就绪，
/// 此处在列表里明确标注而不是静默失败。数据加载逻辑见 `HomeView+Data.swift`。
@MainActor
public struct HomeView: View {
    @ObservedObject var model: AppModel
    @State var selectedSiteKey = ""
    @State var selectedCategoryID = ""
    @State var extend: [String: String] = [:]
    @State var result = SpiderResult()
    @State var page = 1
    @State var isLoading = false
    @State var errorText = ""

    public init(model: AppModel) {
        self.model = model
    }

    /// 可用且走 CMS 通道的站点。
    var cmsSites: [Site] {
        model.sites.filter { $0.kind != .spider }
    }

    var selectedSite: Site? {
        cmsSites.first { $0.key == selectedSiteKey } ?? cmsSites.first
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
            if cmsSites.isEmpty {
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
        .navigationTitle("首页")
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
            if selectedSiteKey.isEmpty {
                selectedSiteKey = cmsSites.first?.key ?? ""
            }
            await loadHome()
        }
        .onChange(of: selectedSiteKey) { _ in
            selectedCategoryID = ""
            extend = [:]
            page = 1
            Task { await loadHome(force: true) }
        }
        .onChange(of: selectedCategoryID) { _ in
            extend = [:]
            page = 1
            Task { await loadCategory() }
        }
    }

    // MARK: - 区块

    private var siteSection: some View {
        Section("站点") {
            Picker("当前站点", selection: $selectedSiteKey) {
                ForEach(cmsSites) { site in
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
                Picker("分类", selection: $selectedCategoryID) {
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
            ForEach(result.list) { item in
                NavigationLink {
                    VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
                } label: {
                    VodRow(item: item)
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
        if model.allSites.isEmpty {
            return "还没有可用站点：请先在「接口管理」里加载配置。"
        }
        if model.loadedKind == .javaScript {
            return "当前是 JS 源（js2p）：站点清单需等内嵌 Node 服务就绪（M1.6 落地）。"
        }
        return "当前配置里没有可直接访问的 CMS 站点（type 0/1/2/4）。"
    }
}
