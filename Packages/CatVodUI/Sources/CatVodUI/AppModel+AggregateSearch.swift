import CatVodCore
import CatVodSource
import Foundation

/// 聚合搜索的结果（+ 诊断）：界面要能说清「墙上为什么没东西」——失败不静默，与仓库其它入口同一口径。
struct AggregateSearchOutcome {
    /// 有命中的站点（左栏 + 右栏的数据源）。
    let sections: [AggregateSearchSection]
    /// 实际搜过的站点数（首轮 + 可能补搜的第二轮）。
    let searchedCount: Int
    /// 失败站点的可读原因（`站点名：原因`），顺序与站点清单一致。
    let failures: [String]
    /// 索引站点首轮零命中后是否补搜了其余可搜站点（界面据此把话说全）。
    let didFallBackToAllSites: Bool
}

extension AppModel {
    /// 聚合搜索**实际会用的站点**：能搜的（可运行 + 允许搜索）减掉用户在「筛选站源」里关掉的。
    ///
    /// 搜索页与详情页 🔍 的海报墙都从这里取站点范围 —— 一个开关管两处。
    var searchEnabledSites: [Site] {
        AggregateSearchRules.enabled(sites: sites, excluding: searchExcludedSiteKeys)
    }

    /// 聚合搜索（M11 片 5 的聚合海报墙）：并发搜参与聚合的站点。
    ///
    /// 口径（与别的搜索刻意不同，写下来免得被「顺手统一」）：
    /// - 站点范围：``AggregateSearchRules/targets(sites:)``（索引站点优先）——
    ///   **首轮一条都没搜到时补搜其余可搜站点**：空墙不等于「别的站点没有」，这面墙是给人挑入口用的；
    /// - **逐站 best-effort，但失败不静默**：某站失败只跳过它、不拖累别的站点，原因带回去给界面显示；
    /// - 每站只取**第一页**：这面墙是「挑一个入口」用的，不是浏览器（要翻页去搜索页）；
    /// - 取图走搜索页同一套 `PictureFiller`：墙上的海报与搜索页看到的应该是同一张。
    func searchAcrossSites(keyword: String) async -> AggregateSearchOutcome {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 站点范围 = 能搜的 − 「筛选站源」里关掉的（两个入口共用这一条，见 searchEnabledSites）。
        let allSearchable = searchEnabledSites
        let indexed = allSearchable.filter { $0.indexs == 1 }
        let firstRound = indexed.isEmpty ? allSearchable : indexed
        guard !trimmed.isEmpty, !firstRound.isEmpty else {
            return AggregateSearchOutcome(
                sections: [],
                searchedCount: firstRound.count,
                failures: [],
                didFallBackToAllSites: false
            )
        }
        let client = makeSiteClient()
        let filler = makePictureFiller()
        var searchedKeys = Set(firstRound.map(\.key))
        var rounds = await searchRound(trimmed, sites: firstRound, client: client, filler: filler)
        var didFallBack = false
        if rounds.hits.isEmpty, !indexed.isEmpty, indexed.count < allSearchable.count {
            // 索引站点一条都没有：把其余的也搜一遍（顺序照站点清单，最后一起归位）。
            let rest = allSearchable.filter { !searchedKeys.contains($0.key) }
            if !rest.isEmpty {
                let fallback = await searchRound(trimmed, sites: rest, client: client, filler: filler)
                searchedKeys.formUnion(rest.map(\.key))
                rounds.hits.merge(fallback.hits) { first, _ in first }
                rounds.failures.merge(fallback.failures) { first, _ in first }
                didFallBack = true
            }
        }
        // 归位顺序统一照**站点清单**：首轮与补搜轮谁先回来都不算数。
        let searchedSites = allSearchable.filter { searchedKeys.contains($0.key) }
        let names = Dictionary(
            searchedSites.map { ($0.key, siteDisplayName(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let failures = searchedSites.compactMap { site -> String? in
            guard let reason = rounds.failures[site.key] else {
                return nil
            }
            return "\(names[site.key] ?? site.key)：\(reason)"
        }
        return AggregateSearchOutcome(
            sections: AggregateSearchRules.sections(sites: searchedSites, hits: rounds.hits, names: names),
            searchedCount: searchedSites.count,
            failures: failures,
            didFallBackToAllSites: didFallBack
        )
    }

    /// 一轮并发搜索：把「命中」与「失败原因」都收上来（逐站 best-effort，失败不静默）。
    private func searchRound(
        _ keyword: String,
        sites: [Site],
        client: SiteClient,
        filler: PictureFiller
    ) async -> (hits: [String: [VodItem]], failures: [String: String]) {
        var hits: [String: [VodItem]] = [:]
        var failures: [String: String] = [:]
        await withTaskGroup(of: SiteSearchOutcome.self) { group in
            for site in sites {
                group.addTask {
                    do {
                        let found = try await client.search(site: site, keyword: keyword)
                        let filled = await filler.fill(site: site, result: found)
                        return SiteSearchOutcome(key: site.key, items: filled.list, failure: nil)
                    } catch {
                        // 只把**可读文案**带过任务边界（`Error` 不保证 `Sendable`，与 `AggregateParser` 同一做法）。
                        return SiteSearchOutcome(key: site.key, items: [], failure: userFacingMessage(error))
                    }
                }
            }
            for await outcome in group {
                if let failure = outcome.failure {
                    failures[outcome.key] = failure
                } else if !outcome.items.isEmpty {
                    hits[outcome.key] = outcome.items
                }
            }
        }
        return (hits, failures)
    }
}

/// 单个站点的搜索结果（内部用）：要么有命中，要么带一条可读的失败原因。
private struct SiteSearchOutcome: Sendable {
    let key: String
    let items: [VodItem]
    let failure: String?
}
