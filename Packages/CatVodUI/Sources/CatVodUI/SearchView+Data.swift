import CatVodCore
import CatVodSource
import SwiftUI

// 搜索页的数据加载逻辑（与视图分离，便于复用与单测）。

extension SearchView {
    /// 是否还能继续加载下一页（判定复用发现页的 `DiscoverPaging`，单测覆盖）。
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

    /// 作废当前结果（换站点 / 换接口时调用）：只改界面状态，不发请求。
    func clearResults() {
        result = SpiderResult()
        page = 1
        submittedKeyword = ""
        reachedEnd = false
        errorText = ""
    }

    /// 发起一次新搜索（搜索框回车 / 点历史里的某一条）。
    ///
    /// 与 `loadMore()` 分开写：新搜索**整页替换**并重置翻页，翻页是**追加**。
    /// 正在搜索时重复提交直接忽略（连点回车不该并发发两遍同样的请求）。
    func startSearch() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请先输入关键词"
            return
        }
        guard let site = selectedSite else {
            errorText = "当前没有可用的站点"
            return
        }
        guard !isLoading else {
            return
        }
        submittedKeyword = trimmed
        // 记入搜索历史（去重置顶、封顶规则在 `SearchHistory` 里，单测覆盖）。
        model.rememberSearch(trimmed)
        page = 1
        reachedEnd = false
        errorText = ""
        isLoading = true
        defer { isLoading = false }

        do {
            let found = try await model.makeSiteClient().search(site: site, keyword: trimmed, page: 1)
            result = await model.makePictureFiller().fill(site: site, result: found)
        } catch {
            errorText = userFacingMessage(error)
            result = SpiderResult()
        }
    }

    /// 上拉加载更多：把下一页**追加**到结果尾部。
    ///
    /// 对齐参考录屏：搜索页也没有分页按钮，滚动到底部自动接着取。
    func loadMore() async {
        guard let site = selectedSite, !isLoading, !submittedKeyword.isEmpty else {
            return
        }
        let nextPage = page + 1
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        do {
            let found = try await model.makeSiteClient().search(
                site: site,
                keyword: submittedKeyword,
                page: nextPage
            )
            let filled = await model.makePictureFiller().fill(site: site, result: found)
            appendPage(filled, number: nextPage)
        } catch {
            errorText = userFacingMessage(error)
        }
    }

    /// 追加一页到结果尾部。
    ///
    /// 空列表是「分页到底」的信号：上游没给 `pagecount` 时，这是唯一能停住上拉加载的依据
    /// （与发现页同一套判定，见 `DiscoverPaging`）。后续页若带上总页数就顺带更新。
    func appendPage(_ incoming: SpiderResult, number: Int) {
        if incoming.list.isEmpty {
            reachedEnd = true
            return
        }
        result.list.append(contentsOf: incoming.list)
        if incoming.pagecount > 0 {
            result.pagecount = incoming.pagecount
        }
        page = number
    }
}
