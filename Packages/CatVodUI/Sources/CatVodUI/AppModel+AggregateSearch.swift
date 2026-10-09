import CatVodCore
import CatVodSource
import Foundation

extension AppModel {
    /// 聚合搜索（M11 片 5 的聚合海报墙）：并发搜参与聚合的站点，返回**有命中**的站点结果。
    ///
    /// 口径（与别的搜索刻意不同，写下来免得被「顺手统一」）：
    /// - 站点范围与归位规则见 ``AggregateSearchRules``；
    /// - 逐站 best-effort：某个站点失败只跳过它，不拖累别的站点（与换源 ``ChangeSourceService`` 同一口径）；
    /// - 每站只取**第一页**：这面墙是「挑一个入口」用的，不是浏览器（要翻页去搜索页）；
    /// - 取图走搜索页同一套 `PictureFiller`：墙上的海报与搜索页看到的应该是同一张。
    func searchAcrossSites(keyword: String) async -> [AggregateSearchSection] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = AggregateSearchRules.targets(sites: sites)
        guard !trimmed.isEmpty, !targets.isEmpty else {
            return []
        }
        let client = makeSiteClient()
        let filler = makePictureFiller()
        var hits: [String: [VodItem]] = [:]
        await withTaskGroup(of: (String, [VodItem]).self) { group in
            for site in targets {
                group.addTask {
                    guard let found = try? await client.search(site: site, keyword: trimmed) else {
                        return (site.key, [])
                    }
                    let filled = await filler.fill(site: site, result: found)
                    return (site.key, filled.list)
                }
            }
            for await (key, items) in group {
                guard !items.isEmpty else {
                    continue
                }
                hits[key] = items
            }
        }
        let names = Dictionary(
            targets.map { ($0.key, siteDisplayName(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return AggregateSearchRules.sections(sites: targets, hits: hits, names: names)
    }
}
