import CatVodCore
import CatVodSource
import SwiftUI

// 首页的数据加载逻辑（与视图分离，便于单测与复用）。

extension HomeView {
    /// 「横向展示」每行的海报张数。
    static let posterColumnCount = 3

    /// 「横向展示」用的换行切片：每 ``posterColumnCount`` 张一行，**末尾补 `nil` 占满**。
    ///
    /// 为什么在数据里补齐：这样每行固定 3 个格子，最后一行的卡片不会被拉宽，
    /// 视图里也不必写 `ForEach(0 ..< n)` 这种**非常量范围**（SwiftUI 不推荐）。
    var posterRows: [[VodItem?]] {
        var rows: [[VodItem?]] = []
        var index = 0
        let items = result.list
        while index < items.count {
            var row: [VodItem?] = []
            for offset in 0 ..< Self.posterColumnCount {
                let itemIndex = index + offset
                row.append(itemIndex < items.count ? items[itemIndex] : nil)
            }
            rows.append(row)
            index += Self.posterColumnCount
        }
        return rows
    }

    /// 筛选器绑定：未选择时使用上游给的初始值。
    func binding(for filter: VodFilter) -> Binding<String> {
        Binding(
            get: { extend[filter.key] ?? filter.initialValue },
            set: { extend[filter.key] = $0 }
        )
    }

    /// 分类选择绑定：**分类加载的唯一入口**。
    ///
    /// 为什么不用 `.onChange(of: selectedCategoryID)`：`loadHome()` / `loadCategory()` 内部也会写
    /// `selectedCategoryID`，用 onChange 会把「一次加载」变成两次请求（同分类同页各发一遍）。
    /// 这里只把「用户改分类」当事件：重置筛选与翻页 → 加载一次。
    var categoryBinding: Binding<String> {
        Binding(
            get: { selectedCategoryID },
            set: { newValue in
                // Picker 在初次布局时可能回写同一个值：值没变就不发请求。
                guard newValue != selectedCategoryID else {
                    return
                }
                selectedCategoryID = newValue
                extend = [:]
                page = 1
                Task { await loadCategory() }
            }
        )
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

    /// 作废「与当前站点绑定」的界面状态：换接口 / 换站点后必须整体重来。
    ///
    /// 只改界面状态、不发请求：请求由调用方决定走 `loadHome(force:)`
    /// 还是交给 `.onChange(of: selectedSiteKey)` 统一发起。
    func invalidateContent() {
        selectedCategoryID = ""
        extend = [:]
        page = 1
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
        defer { isLoading = false }

        // 首页缓存（设置 → 数据 → 缓存管理 → 首页缓存时间）：命中就直接用，一个请求都不发。
        let cacheKey = HomeCacheStore.Key(
            siteKey: targetSite.key,
            categoryID: targetCategory,
            page: page,
            extend: extend
        )
        if !force, let cached = model.cachedHomeResult(cacheKey) {
            result = cached
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
                result = filled
                model.storeHomeResult(filled, key: cacheKey)
            }
            if selectedCategoryID != targetCategory {
                selectedCategoryID = targetCategory
            }
        } catch {
            errorText = describe(error)
        }
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

/// 海报卡片：首页「横向展示」用（封面 + 片名 + 备注）。
///
/// 与 ``VodRow`` 同源同数据，只是换了排布；高度固定，保证同一行里的卡片底部对齐。
struct PosterCard: View {
    let item: VodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: URL(string: item.vodPic)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))

            Text(item.vodName.isEmpty ? item.vodID : item.vodName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !item.vodRemarks.isEmpty {
                Text(item.vodRemarks)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
