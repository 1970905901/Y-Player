@testable import CatVodCore
import Foundation
import Testing

/// 解析规则（``SniffRule``）的 `exclude` → 清理器规则。
///
/// 对齐参考实现 `HlsRuleConfig#compileLegacyRules`：`hosts` 当清单作用域、`exclude` 当分片正则、
/// `regex` 不参与；没有 `exclude` 的规则整条跳过。
///
/// ⚠️ 这条路走的是**解析规则**（配置里的 `rules`），不是 `hlsRules`（那个是规则包形态，见
/// `SourceConfigHLSRulesTests`）—— M06d 先搞混过一次，才把 `hlsRules` 的形状修正过来。
@Suite("解析规则的 exclude → 清理器规则（对齐 compileLegacyRules）")
struct SniffRuleCleanerMappingTests {
    private let baseURL = "https://video.example.com/index.m3u8"

    @Test("hosts 当作用域、exclude 当分片正则：清单 host 不匹配就不删")
    func mapsHostsAndExclude() throws {
        let config = SniffRule(hosts: ["video\\.example\\.com"], regex: ["不参与"], exclude: ["/preroll/"])
        let rule = try #require(config.compiledAdRule())
        #expect(rule.id.hasPrefix("legacy:"))

        let manifest = "#EXTM3U\n"
            + "#EXTINF:7.0,\nhttps://cdn.example.com/preroll/ad.ts\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
            + "#EXT-X-ENDLIST\n"

        let other = HLSManifestCleaner.clean(
            baseURL: "https://other.example.com/index.m3u8",
            manifest: manifest,
            rules: [rule]
        )
        #expect(!other.changed)

        let matched = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])
        #expect(matched.changed)
        #expect(!matched.manifest.contains("ad.ts"))
    }

    @Test("没有 exclude 的规则整条跳过（留着只会变成「命中一切」）")
    func skipsRuleWithoutExclude() {
        #expect(SniffRule(hosts: ["a.example.com"], regex: ["x"], exclude: []).compiledAdRule() == nil)
    }

    @Test("规则 id 稳定：同一份配置每次算出来一样，换了内容就变")
    func idIsStable() throws {
        let first = try #require(SniffRule(hosts: ["a.example.com"], exclude: ["/ad/"]).compiledAdRule())
        let again = try #require(SniffRule(hosts: ["a.example.com"], exclude: ["/ad/"]).compiledAdRule())
        let other = try #require(SniffRule(hosts: ["a.example.com"], exclude: ["/other/"]).compiledAdRule())

        #expect(first.id == again.id)
        #expect(first.id != other.id)
    }

    @Test("规则盒子：默认空、更新后能读到（本机服务每请求读的就是它）")
    func ruleStoreHoldsCurrentRules() throws {
        let store = HLSAdRuleStore()
        #expect(store.current.isEmpty)

        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)
        store.update([rule])
        #expect(store.current.count == 1)

        store.update([])
        #expect(store.current.isEmpty)
    }
}
