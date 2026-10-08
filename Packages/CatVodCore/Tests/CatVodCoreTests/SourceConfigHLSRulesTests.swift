@testable import CatVodCore
import Foundation
import Testing

/// 配置里 `hlsRules` 的**形状**（M06d 修正后的回归测试）。
///
/// 上游这个字段是**规则包形态** —— `VodConfig` / `LiveConfig` 里都是
/// `setHlsRules(HlsAdRule.arrayFrom(fetchArray(object, "hlsRules")))`。
/// 本项目曾经按 `rules` 那种 `{hosts, regex, exclude}` 建模，后果是**静默失效**：
/// 解析不报错，但真配置里的规则一条都匹配不上。这里用一段真形状的 JSON 把这件事钉住。
@Suite("配置里的 hlsRules 形状（M06d 修正）")
struct SourceConfigHLSRulesTests {
    private func config(_ json: String) throws -> SourceConfig {
        try JSONDecoder().decode(SourceConfig.self, from: Data(json.utf8))
    }

    @Test("真形状（规则包形态）能解析出来，并且能编成清理器规则")
    func decodesPackageShape() throws {
        let json = #"{"sites":[],"hlsRules":[{"id":"cfg.preroll","name":"配置里的规则","# +
            #""enabled":true,"playlistHostSuffixes":["video.example.com"],"# +
            #""hostSuffixes":["ads.example.com"],"segmentUrlRegex":["/preroll/"],"minimumSignals":2}]}"#
        let value = try config(json)

        #expect(value.hlsRules.count == 1)
        let rule = try #require(value.hlsRules.first)
        #expect(rule.id == "cfg.preroll")
        #expect(rule.playlistHostSuffixes == ["video.example.com"])
        #expect(rule.hostSuffixes == ["ads.example.com"])
        #expect(rule.segmentUrlRegex == ["/preroll/"])
        #expect(rule.minimumSignals == 2)
        #expect(rule.isEnabled)

        let manifest = "#EXTM3U\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/preroll/ad.ts\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXT-X-ENDLIST\n"
        let result = try HLSManifestCleaner.clean(
            baseURL: "https://video.example.com/index.m3u8",
            manifest: manifest,
            rules: [rule.compile()]
        )
        #expect(result.changed)
        #expect(!result.manifest.contains("ad.ts"))
    }

    @Test("没写 `enabled` 的规则不算开（对齐 compileExternal 的 `rule.isEnabled()`）")
    func disabledByDefaultWhenNotExplicitlyEnabled() throws {
        let json = #"{"sites":[],"hlsRules":[{"id":"cfg.off","playlistHostSuffixes":["v.example.com"],"# +
            #""hostSuffixes":["ads.example.com"],"minimumSignals":1}]}"#
        let rule = try #require(try config(json).hlsRules.first)

        #expect(!rule.isEnabled)
    }

    @Test("旧形状写进 `hlsRules` 会解析成空规则 → 不会被启用（失败也不静默半生效）")
    func legacyShapeInHLSSlotFailsSafe() throws {
        let json = #"{"sites":[],"hlsRules":[{"hosts":["video.example.com"],"exclude":["/preroll/"]}]}"#
        let rule = try #require(try config(json).hlsRules.first)

        #expect(rule.id.isEmpty)
        #expect(!rule.isEnabled)
        // 真按它编会明确失败（缺 id），而不是「编出一条能匹配一切的规则」
        #expect(throws: HLSManifestCleaner.Failure.missingRuleID) { _ = try rule.compile() }
    }

    @Test("解析规则的 `exclude` 仍在 `rules` 里，两者不会互相串味")
    func sniffRulesStaySeparate() throws {
        let json = #"{"sites":[],"rules":[{"name":"嗅探","hosts":["cdn.example.com"],"exclude":["/ad/"]}],"hlsRules":[]}"#
        let value = try config(json)

        #expect(value.rules.count == 1)
        #expect(value.rules.first?.exclude == ["/ad/"])
        #expect(value.hlsRules.isEmpty)
        #expect(value.rules.first?.compiledAdRule() != nil)
    }
}
