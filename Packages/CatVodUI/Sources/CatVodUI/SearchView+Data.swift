import CatVodCore
import Foundation

// 搜索页的动作：**只决定「搜什么」** —— 发请求与并发交给墙面（`AggregateSearchWall`）。
//
// 老版在这里直接打请求（一次一个站点 + 上拉翻页），聚合版把这活交出去了；
// 所以这个文件现在只剩「提交」这一件事。

extension SearchView {
    /// 提交搜索（回车 / 点历史里的某一条）。
    ///
    /// 三件事：裁空白、记历史、换关键词（墙按 `.task(id:)` 重搜）。
    /// `submitRevision` 每次 +1：同一个词再提交一次也要重搜（否则 `.task(id:)` 认为没变化）。
    func submitSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        keyword = trimmed
        model.rememberSearch(trimmed)
        submitRevision += 1
        submittedKeyword = trimmed
    }
}
