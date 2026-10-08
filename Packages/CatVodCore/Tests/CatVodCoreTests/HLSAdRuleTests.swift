@testable import CatVodCore
import Foundation
import Testing

/// HLS 广告规则：JSON → 编译成清理器规则时的校验。
///
/// 对齐参考实现 `HlsAdRuleTest` / `HlsRulePackageTest`。重点在**该拒的必须拒**：
/// 没有作用域、信号数为 0、`minimumSignals` 越界、正则危险、时长只给一半 —— 每条单独钉一个用例。
/// 理由：清理规则一旦被放宽，误删的就是正常内容。
@Suite("HLS 广告规则（对齐 HlsAdRule）")
struct HLSAdRuleTests {
    @Test("JSON 编出来就能用：作用域 + 三个信号")
    func compilesJSONRuleIntoMatcher() throws {
        let json = #"{"id":"test.preroll.v1","playlistHostSuffixes":["video.example.com"],"# +
            #""hostSuffixes":["ads.example.com"],"segmentUrlRegex":["/preroll/"],"# +
            #""minDuration":6.5,"maxDuration":7.5,"minimumSignals":3,"enabled":true}"#
        let rule = try #require(HLSAdRule.parse(json))
        #expect(rule.id == "test.preroll.v1")
        #expect(rule.signalCount == 3)
        #expect(rule.enabled == true)

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

    @Test("缺 id：拒收（id 是统计与开关的身份，不能空）")
    func rejectsMissingID() throws {
        let rule = try #require(HLSAdRule.parse(
            #"{"playlistHostSuffixes":["video.example.com"],"hostSuffixes":["ads.example.com"],"minimumSignals":1}"#
        ))
        #expect(throws: HLSManifestCleaner.Failure.missingRuleID) { _ = try rule.compile() }
    }

    @Test("没有作用域：拒收（否则会命中所有站点）")
    func rejectsMissingPlaylistScope() throws {
        let rule = try #require(HLSAdRule.parse(
            #"{"id":"test.scope","hostSuffixes":["ads.example.com"],"minimumSignals":1}"#
        ))
        #expect(throws: HLSManifestCleaner.Failure.missingPlaylistScope) { _ = try rule.compile() }
    }

    @Test("minimumSignals 越界（0 / 大于信号数）：拒收")
    func rejectsInvalidMinimumSignals() throws {
        let zero = try #require(HLSAdRule.parse(
            #"{"id":"test.zero","playlistHostSuffixes":["v.example.com"],"hostSuffixes":["ads.example.com"],"minimumSignals":0}"#
        ))
        #expect(throws: HLSManifestCleaner.Failure.invalidMinimumSignals) { _ = try zero.compile() }

        let tooMany = try #require(HLSAdRule.parse(
            #"{"id":"test.toomany","playlistHostSuffixes":["v.example.com"],"hostSuffixes":["ads.example.com"],"minimumSignals":2}"#
        ))
        #expect(throws: HLSManifestCleaner.Failure.invalidMinimumSignals) { _ = try tooMany.compile() }
    }

    @Test("时长只给一半：拒收（半截区间会变成「猜」）")
    func rejectsIncompleteDurationRange() throws {
        let rule = try #require(HLSAdRule.parse(
            #"{"id":"test.half","playlistHostSuffixes":["v.example.com"],"minDuration":6.5,"minimumSignals":1}"#
        ))
        // minDuration 有、maxDuration 没有 → 信号数按 0 算，先撞上信号数校验还是区间校验都算对，
        // 这里只要求「拒收」这件事本身
        #expect(throws: (any Error).self) { _ = try rule.compile() }
    }

    @Test("危险正则（连续 .*／嵌套量词）：拒收")
    func rejectsDangerousPatterns() throws {
        let rule = try #require(HLSAdRule.parse(
            #"{"id":"test.danger","playlistHostSuffixes":["v.example.com"],"segmentUrlRegex":[".*.*ad"],"minimumSignals":1}"#
        ))
        #expect(throws: HLSManifestCleaner.Failure.self) { _ = try rule.compile() }

        // 嵌套量词（回溯爆炸的经典写法）在**编译期**就该被拒，而不是等它跑起来
        #expect(throws: HLSManifestCleaner.Failure.self) {
            _ = try HLSManifestCleaner.Rule(segmentUrlPatterns: ["(a+)*b"])
        }
    }

    @Test("空字符串正则 / 空 host 后缀：拒收")
    func rejectsBlankEntries() throws {
        let blankRegex = try #require(HLSAdRule.parse(
            #"{"id":"test.blank","playlistHostSuffixes":["v.example.com"],"segmentUrlRegex":[""],"minimumSignals":1}"#
        ))
        #expect(throws: HLSManifestCleaner.Failure.self) { _ = try blankRegex.compile() }

        let blankHost = try #require(HLSAdRule.parse(
            #"{"id":"test.blankhost","playlistHostSuffixes":["v.example.com"],"hostSuffixes":[""],"minimumSignals":1}"#
        ))
        #expect(throws: HLSManifestCleaner.Failure.self) { _ = try blankHost.compile() }
    }

    @Test("坏 JSON / 缺字段：解析成「没配」而不是崩")
    func toleratesMalformedJSON() {
        #expect(HLSAdRule.parse("not-json") == nil)
        // 缺字段时按零值走（enabled 是 nil = 没设过），然后由 compile() 那道校验拦住
        let minimal = HLSAdRule.parse("{}")
        #expect(minimal?.id.isEmpty == true)
        #expect(minimal?.enabled == nil)
        #expect(HLSAdRule.parseArray("not-json").isEmpty)
    }
}
