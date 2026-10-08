@testable import CatVodCore
import Foundation
import Testing

/// 接口配置里的 `hlsRules`（`hosts` / `regex` / `exclude`）→ 清理器规则。
///
/// 对齐参考实现 `HlsRuleConfig#compileLegacyRules`：`hosts` 当清单作用域、`exclude` 当分片正则、
/// `regex` 不参与；没有 `exclude` 的规则整条跳过。
@Suite("接口配置的 hlsRules → 清理器规则")
struct HlsRuleCleanerMappingTests {
    private let baseURL = "https://video.example.com/index.m3u8"

    @Test("hosts 当作用域、exclude 当分片正则：清单 host 不匹配就不删")
    func mapsHostsAndExclude() throws {
        let config = HlsRule(hosts: ["video\\.example\\.com"], regex: ["不参与"], exclude: ["/preroll/"])
        let rule = try #require(config.compiledAdRule())
        #expect(rule.id.hasPrefix("legacy:"))

        let manifest = "#EXTM3U\n"
            + "#EXTINF:7.0,\nhttps://cdn.example.com/preroll/ad.ts\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
            + "#EXT-X-ENDLIST\n"

        let other = HLSManifestCleaner.clean(baseURL: "https://other.example.com/index.m3u8",
                                             manifest: manifest,
                                             rules: [rule])
        #expect(!other.changed)

        let matched = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])
        #expect(matched.changed)
        #expect(!matched.manifest.contains("ad.ts"))
    }

    @Test("没有 exclude 的规则整条跳过（留着只会变成「命中一切」）")
    func skipsRuleWithoutExclude() {
        #expect(HlsRule(hosts: ["a.example.com"], regex: ["x"], exclude: []).compiledAdRule() == nil)
    }

    @Test("规则 id 稳定：同一份配置每次算出来一样，换了内容就变")
    func idIsStable() throws {
        let first = try #require(HlsRule(hosts: ["a.example.com"], exclude: ["/ad/"]).compiledAdRule())
        let again = try #require(HlsRule(hosts: ["a.example.com"], exclude: ["/ad/"]).compiledAdRule())
        let other = try #require(HlsRule(hosts: ["a.example.com"], exclude: ["/other/"]).compiledAdRule())

        #expect(first.id == again.id)
        #expect(first.id != other.id)
    }
}
