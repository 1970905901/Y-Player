import CatVodCore
import CatVodSource
import Foundation

/// 聚合搜索的结果（+ 诊断）：界面要能说清「墙上为什么没东西」——失败不静默，与仓库其它入口同一口径。
struct AggregateSearchOutcome {
    /// 有命中的站点（左栏 + 右栏的数据源）。
    let sections: [AggregateSearchSection]
    /// 实际搜过的站点数（= 规则选出来的目标站点数）。
    let searchedCount: Int
    /// 失败站点的可读原因（`站点名：原因`），顺序与站点清单一致。
    let failures: [String]
}

extension AppModel {
    /// 聚合搜索（M11 片 5 的聚合海报墙）：并发搜参与聚合的站点。
    ///
    /// 口径（与别的搜索刻意不同，写下来免得被「顺手统一」）：
    /// - 站点范围与归位规则见 ``AggregateSearchRules``；
    /// - **逐站 best-effort，但失败不静默**：某站失败只跳过它、不拖累别的站点，原因带回去给界面显示；
    /// - 每站只取**第一页**：这面墙是「挑一个入口」用的，不是浏览器（要翻页去搜索页）；
    /// - 取图走搜索页同一套 `PictureFiller`：墙上的海报与搜索页看到的应该是同一张。
    func searchAcrossSites(keyword: String) async -> AggregateSearchOutcome {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = AggregateSearchRules.targets(sites: sites)
        guard !trimmed.isEmpty, !targets.isEmpty else {
            return AggregateSearchOutcome(sections: [], searchedCount: targets.count, failures: [])
        }
        let names = Dictionary(
            targets.map { ($0.key, siteDisplayName(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let client = makeSiteClient()
        let filler = makePictureFiller()
        var hits: [String: [VodItem]] = [:]
        var failures: [String: String] = [:]
        await withTaskGroup(of: SiteSearchOutcome.self) { group in
            for site in targets {
                group.addTask {
                    do {
                        let found = try await client.search(site: site, keyword: trimmed)
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
        return AggregateSearchOutcome(
            sections: AggregateSearchRules.sections(sites: targets, hits: hits, names: names),
            searchedCount: targets.count,
            failures: targets.compactMap { site in
                failures[site.key].map { "\(names[site.key] ?? site.key)：\($0)" }
            }
        )
    }
}

/// 单个站点的搜索结果（内部用）：要么有命中，要么带一条可读的失败原因。
private struct SiteSearchOutcome: Sendable {
    let key: String
    let items: [VodItem]
    let failure: String?
}
