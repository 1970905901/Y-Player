import CatVodCore
import CatVodSource
import SwiftUI

// 发现页（`HomeView`）的数据加载逻辑（与视图分离，便于单测与复用）。

extension HomeView {
    /// 「横向展示」每行的海报张数（参考视频的网格是 3 列）。
    static let posterColumnCount = 3

    /// 是否还能继续加载下一页（判定逻辑在 `DiscoverPaging`，单测覆盖）。
    var canLoadMore: Bool {
        DiscoverPaging.canLoadMore(
            page: page,
            pageCount: result.pagecount,
            itemCount: result.list.count,
            reachedEnd: reachedEnd
        )
    }

    /// `.task(id:)` 的触发键：页码或条数变化都重新尝试取下一页。
    var loadMoreTrigger: String {
        "\(page)-\(result.list.count)"
    }

    /// 切换分类（分类条点击）：重置筛选与翻页，然后加载第一页。
    ///
    /// 为什么不做成 `Binding` + `.onChange`：`loadHome()` / `loadCategory()` 内部也会回写
    /// `selectedCategoryID`，用 onChange 会把「一次加载」变成两次请求（同分类同页各发一遍）。
    /// 这里只把「用户改分类」当事件。
    func selectCategory(_ categoryID: String) {
        guard !categoryID.isEmpty, categoryID != selectedCategoryID else {
            return
        }
        selectedCategoryID = categoryID
        extend = [:]
        page = 1
        reachedEnd = false
        Task { await loadCategory() }
    }

    /// 点筛选胶囊：**立即生效**（参考视频里没有「应用筛选」按钮）。
    ///
    /// 与当前选中值相同就不重发请求（点在当前项上不该白刷一次）。
    func applyFilter(_ row: DiscoverFilterRow, value: String) {
        guard row.selectedValue != value else {
            return
        }
        extend[row.key] = value
        page = 1
        reachedEnd = false
        Task { await loadCategory() }
    }

    /// 让首页与「当前接口的站点清单」保持一致。
    ///
    /// 两个调用点：`.task`（首页出现）与 `.onChange(of: model.siteCatalogRevision)`
    /// （配置加载完成 / 宿主站点刷新 / 宿主停止）。为什么两条路都得走：
    /// `TabView` 里的首页是**常驻**视图，`.task` 在回到已存在的 Tab 时不保证重跑；
    /// 即便重跑，`loadHome()` 也会因为已有分类直接返回 —— 旧行为只能靠**杀进程冷启动**
    /// 才看到新接口的站点（见 `docs/任务记录/M02P9-接口变更后的自动刷新.md`）。
    func syncHomeWithInterface() async {
        let catalogChanged = loadedCatalogRevision != model.siteCatalogRevision
        loadedCatalogRevision = model.siteCatalogRevision

        let firstKey = browsableSites.first?.key ?? ""
        if selectedSiteKey != firstKey {
            // 站点已换（或当前选中的站点已不存在）：改选首个可用站点。
            // 加载交给 `.onChange(of: selectedSiteKey)` 统一发起，避免同一次切换发两次请求。
            if catalogChanged {
                invalidateContent()
            }
            selectedSiteKey = firstKey
            return
        }
        guard !selectedSiteKey.isEmpty else {
            // 当前接口没有可用站点（空配置 / 加载失败 / 宿主失败）：清掉上一个接口的残留，
            // 空态说明由视图的 `emptyHint` 给出。
            invalidateContent()
            return
        }
        if catalogChanged {
            invalidateContent()
        }
        // 接口没换（只是首页又出现了一次）时，`loadHome()` 会因为已有分类直接返回，不会重复请求。
        await loadHome()
    }

    /// 横向展示的数据：为每个分区（分类）各取一页。
    ///
    /// 为什么要并发：一个接口常有十来个分类，串行取完要等十几次往返、首屏长时间空白。
    /// 这里只取**前几个**（`HomeView.sectionCategoryLimit`，参考图第一屏可见的就三四个），
    /// 用 `TaskGroup` 并发；回来的顺序是乱的，所以最后**按分类原顺序排回去** ——
    /// 分区顺序跟分类条不一致，会让人以为串台了。
    ///
    /// 失败或空的分区**不占位**（跳过），也不弹错误：横向模式本来就是「看个大概」，
    /// 某个分类挂了不该把整页变红。
    func loadSections() async {
        guard sections.isEmpty, !isLoadingSections, let site = selectedSite else {
            return
        }
        let targets = Array(result.categories.prefix(Self.sectionCategoryLimit))
        guard !targets.isEmpty else {
            return
        }
        isLoadingSections = true
        defer { isLoadingSections = false }
        let client = model.makeSiteClient()
        var loaded: [DiscoverSection] = []
        await withTaskGroup(of: DiscoverSection?.self) { group in
            for category in targets {
                group.addTask {
                    guard let page = try? await client.category(site: site, categoryID: category.typeID, page: 1) else {
                        return nil
                    }
                    guard !page.list.isEmpty else {
                        return nil
                    }
                    return DiscoverSection(id: category.typeID, title: category.typeName, items: page.list)
                }
            }
            for await section in group {
                if let section {
                    loaded.append(section)
                }
            }
        }
        sections = targets.compactMap { target in
            loaded.first { $0.id == target.typeID }
        }
    }

    /// 作废「与当前站点绑定」的界面状态：换接口 / 换站点后必须整体重来。
    ///
    /// 只改界面状态、不发请求：请求由调用方决定走 `loadHome(force:)`
    /// 还是交给 `.onChange(of: selectedSiteKey)` 统一发起。
    func invalidateContent() {
        selectedCategoryID = ""
        extend = [:]
        page = 1
        reachedEnd = false
        result = SpiderResult()
        errorText = ""
    }

    /// 加载首页（分类 + 首屏内容）。
    func loadHome(force: Bool = false) async {
        guard let site = selectedSite else {
            return
        }
        if !force, !result.categories.isEmpty {
            return
        }
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        do {
            result = try await loadHomeResult(site: site, force: force)
            let firstCategoryID = result.categories.first?.typeID ?? ""
            if selectedCategoryID.isEmpty {
                selectedCategoryID = firstCategoryID
            }
            let targetCategory = selectedCategoryID.isEmpty ? firstCategoryID : selectedCategoryID
            if !targetCategory.isEmpty {
                await loadCategory(categoryID: targetCategory, site: site, force: force)
            }
        } catch {
            errorText = describe(error)
        }
    }

    /// 取首页数据（分类清单 + 首屏内容）：先看首页缓存，命中就**不发请求**。
    ///
    /// 缓存键用 `categoryID: ""`，与分类页区分开 —— 首页返回的是分类清单本身，
    /// 不是某个分类下的某一页内容，两者不能互相顶掉。
    func loadHomeResult(site: Site, force: Bool) async throws -> SpiderResult {
        let key = HomeCacheStore.Key(siteKey: site.key, categoryID: "", page: 1)
        if !force, let cached = model.cachedHomeResult(key) {
            return cached
        }
        let home = try await model.makeSiteClient().home(site: site)
        // 补图是 best-effort：失败或站点不支持时原样返回，不打断首页。
        let filled = await model.makePictureFiller().fill(site: site, result: home)
        model.storeHomeResult(filled, key: key)
        return filled
    }

    /// 加载某个分类的某页。
    ///
    /// - Parameter force: 为 true 时绕过首页缓存（工具栏「刷新」用）；其余入口
    ///   （切换分类、应用筛选、翻页）都允许命中缓存。
    func loadCategory(categoryID: String? = nil, site: Site? = nil, force: Bool = false) async {
        guard let targetSite = site ?? selectedSite else {
            return
        }
        let targetCategory = categoryID ?? selectedCategoryID
        guard !targetCategory.isEmpty else {
            return
        }
        isLoading = true
        errorText = ""
        // 整页替换式加载：每次都要重新判断「能不能继续往下加载」。
        reachedEnd = false
        defer { isLoading = false }

        // 首页缓存（设置 → 数据 → 缓存管理 → 首页缓存时间）：命中就直接用，一个请求都不发。
        let cacheKey = HomeCacheStore.Key(
            siteKey: targetSite.key,
            categoryID: targetCategory,
            page: page,
            extend: extend
        )
        if !force, let cached = model.cachedHomeResult(cacheKey) {
            result = DiscoverContentMerge.content(preservingCategories: cached, current: result)
            if selectedCategoryID != targetCategory {
                selectedCategoryID = targetCategory
            }
            return
        }

        do {
            let category = try await model.makeSiteClient().category(
                site: targetSite,
                categoryID: targetCategory,
                page: page,
                extend: extend
            )
            let filled = await model.makePictureFiller().fill(site: targetSite, result: category)
            if filled.hasList || filled.hasCategories || filled.code == 0 {
                result = DiscoverContentMerge.content(preservingCategories: filled, current: result)
                model.storeHomeResult(filled, key: cacheKey)
            }
            if selectedCategoryID != targetCategory {
                selectedCategoryID = targetCategory
            }
        } catch {
            errorText = describe(error)
        }
    }

    /// 上拉加载更多：把下一页**追加**到列表尾部。
    ///
    /// 与 `loadCategory()`（整页替换）分开写，避免把「翻页」和「换分类 / 换筛选」混成一条路径。
    /// 对齐参考录屏：发现页没有分页按钮，滚动到底部自动接着取。
    func loadMore() async {
        guard let targetSite = selectedSite, !isLoading else {
            return
        }
        let current = selectedCategoryID.isEmpty ? (result.categories.first?.typeID ?? "") : selectedCategoryID
        guard !current.isEmpty else {
            return
        }
        let nextPage = page + 1
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        let cacheKey = HomeCacheStore.Key(
            siteKey: targetSite.key,
            categoryID: current,
            page: nextPage,
            extend: extend
        )
        if let cached = model.cachedHomeResult(cacheKey) {
            appendPage(cached, number: nextPage)
            return
        }

        do {
            let category = try await model.makeSiteClient().category(
                site: targetSite,
                categoryID: current,
                page: nextPage,
                extend: extend
            )
            let filled = await model.makePictureFiller().fill(site: targetSite, result: category)
            appendPage(filled, number: nextPage)
            model.storeHomeResult(filled, key: cacheKey)
        } catch {
            errorText = describe(error)
        }
    }

    /// 追加一页到列表尾部。
    ///
    /// 空列表是「分页到底」的信号：上游没给 `pagecount` 时，这是唯一能停住上拉加载的依据。
    /// 后续页若带上分类 / 筛选 / 总页数（少见但上游确实会）就一并更新，否则保持原样。
    func appendPage(_ incoming: SpiderResult, number: Int) {
        if incoming.list.isEmpty {
            reachedEnd = true
            return
        }
        result.list.append(contentsOf: incoming.list)
        if incoming.hasCategories {
            result.categories = incoming.categories
        }
        if !incoming.filters.isEmpty {
            result.filters = incoming.filters
        }
        if incoming.pagecount > 0 {
            result.pagecount = incoming.pagecount
        }
        page = number
    }

    func describe(_ error: Error) -> String {
        userFacingMessage(error)
    }
}

/// 内容行：海报 + 标题 + 备注。
struct VodRow: View {
    let item: VodItem

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: item.vodPic)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 60, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.vodName.isEmpty ? item.vodID : item.vodName)
                if !item.vodRemarks.isEmpty {
                    Text(item.vodRemarks)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.isFolder {
                    Text("文件夹")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
