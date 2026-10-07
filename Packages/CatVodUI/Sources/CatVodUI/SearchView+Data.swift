import CatVodCore
import CatVodSource
import SwiftUI

// 搜索页的数据加载逻辑（与视图分离，便于复用与后续单测）。

extension SearchView {
    /// 执行搜索。
    ///
    /// - Parameter targetPage: 目标页；传 nil 表示「用输入框里的关键词从第 1 页搜」。
    func runSearch(targetPage: Int? = nil) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            submittedKeyword = trimmed
        }
        guard !submittedKeyword.isEmpty else {
            errorText = "请先输入关键词"
            return
        }
        guard let site = selectedSite else {
            errorText = "当前没有可用的 CMS 站点"
            return
        }

        let nextPage = max(targetPage ?? 1, 1)
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        do {
            let found = try await model.makeCMSClient().search(
                site: site,
                keyword: submittedKeyword,
                page: nextPage
            )
            result = await model.makePictureFiller().fill(site: site, result: found)
            page = nextPage
        } catch {
            errorText = userFacingMessage(error)
        }
    }
}
