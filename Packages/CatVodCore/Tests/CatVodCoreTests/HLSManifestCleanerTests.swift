@testable import CatVodCore
import Foundation
import Testing

/// HLS 广告清理：**逐条对齐参考实现的测试**（`app/src/test/java/com/fongmi/android/tv/utils/HlsManifestCleanerTest.java`）。
///
/// 这个套件最重要的是那批「**宁可不删**」的用例 —— 清理器删错一段就是画面缺一块，
/// 所以每条安全阀（比例、总时长、直播清单、字节范围、低延迟清单、序列号）都单独钉一个用例。
@Suite("HLS 广告清理（对齐 HlsManifestCleaner）")
struct HLSManifestCleanerTests {
    private let baseURL = "https://video.example.com/path/index.m3u8"

    @Test("两个独立信号都命中才删（host 后缀 + URL 正则）")
    func removesCompleteSegmentEntryWhenTwoSignalsMatch() throws {
        let manifest = "#EXTM3U\n"
            + "#EXT-X-TARGETDURATION:8\n"
            + "#EXT-X-DISCONTINUITY\n"
            + "#EXTINF:7.166667,\n"
            + "https://ads.example.com/preroll/ad-1.ts\n"
            + "#EXT-X-DISCONTINUITY\n"
            + "#EXTINF:8.0,\n"
            + "main-1.ts\n"
            + "#EXTINF:8.0,\n"
            + "main-2.ts\n"
            + "#EXT-X-ENDLIST\n"
        let rule = try HLSManifestCleaner.Rule(
            hostSuffixes: ["ads.example.com"],
            segmentUrlPatterns: ["/preroll/"],
            minimumSignals: 2
        )

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.changed)
        #expect(result.removedSegments == 1)
        #expect(!result.manifest.contains("ad-1.ts"))
        #expect(!result.manifest.contains("#EXTINF:7.166667"))
        #expect(result.manifest.contains("main-1.ts"))
        #expect(result.manifest.hasPrefix("#EXTM3U"))
    }

    @Test("规则没命中：一个字都不改")
    func leavesManifestUnchangedWhenRuleDoesNotMatch() throws {
        let manifest = "#EXTM3U\n#EXTINF:8.0,\nmain-1.ts\n#EXT-X-ENDLIST\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(!result.changed)
        #expect(result.manifest == manifest)
    }

    @Test("删得太多（比例超 35%）→ 整体放弃")
    func fallsBackWhenRuleWouldRemoveTooMuchContent() throws {
        let manifest = "#EXTM3U\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/ad-1.ts\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/ad-2.ts\n"
            + "#EXTINF:8.0,\nmain.ts\n"
            + "#EXT-X-ENDLIST\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.fallback)
        #expect(!result.changed)
        #expect(result.manifest == manifest)
    }

    @Test("主清单（没有 #EXTINF）不动")
    func doesNotFilterMasterPlaylist() throws {
        let manifest = "#EXTM3U\r\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=800000\r\n"
            + "low/index.m3u8\r\n"
        let rule = try HLSManifestCleaner.Rule(segmentUrlPatterns: ["index\\.m3u8"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(!result.changed)
        #expect(result.manifest == manifest)
    }

    @Test("半截片段（只有 #EXTINF 没有地址）不动")
    func leavesIncompleteSegmentEntryUnchanged() throws {
        let manifest = "#EXTM3U\n#EXTINF:7.0,\n"
        let rule = try HLSManifestCleaner.Rule(segmentUrlPatterns: [".*"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(!result.changed)
        #expect(result.manifest == manifest)
    }

    @Test("信号数不够：只有时长命中，minimumSignals=2 就不删")
    func requiresConfiguredNumberOfIndependentSignals() throws {
        let manifest = "#EXTM3U\n"
            + "#EXTINF:7.166667,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
            + "#EXT-X-ENDLIST\n"
        let rule = try HLSManifestCleaner.Rule(durationRange: 7.0 ... 7.3, minimumSignals: 2)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(!result.changed)
        #expect(result.manifest == manifest)
    }

    @Test("跨域 + 不连续块：删掉并报出删除时长")
    func removesCrossDomainDiscontinuityBlockAndReportsDuration() throws {
        let manifest = "#EXTM3U\n"
            + "#EXT-X-DISCONTINUITY\n"
            + "#EXTINF:7.0,\nhttps://cdn.other.example/ad.ts\n"
            + "#EXT-X-DISCONTINUITY\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXT-X-ENDLIST\n"
        let rule = try HLSManifestCleaner.Rule(requireDiscontinuity: true,
                                               requireCrossDomain: true,
                                               minimumSignals: 2)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.changed)
        #expect(result.removedSegments == 1)
        #expect(abs(result.removedDurationSec - 7.0) < 0.001)
        #expect(!result.manifest.contains("ad.ts"))
        // 两个 #EXT-X-DISCONTINUITY 不能挤在一起（边界标签跟着被删的片段一起走）
        #expect(!result.manifest.contains("#EXT-X-DISCONTINUITY\n#EXT-X-DISCONTINUITY"))
    }

    @Test("直播清单：删开头那几段，并把两个序列号往前推")
    func removesLeadingLiveSegmentAndAdvancesSequences() throws {
        let manifest = "#EXTM3U\n"
            + "#EXT-X-MEDIA-SEQUENCE:100\n"
            + "#EXT-X-DISCONTINUITY-SEQUENCE:5\n"
            + "#EXT-X-DISCONTINUITY\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/ad.ts\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.changed)
        #expect(!result.fallback)
        #expect(result.manifest.contains("#EXT-X-MEDIA-SEQUENCE:101"))
        #expect(result.manifest.contains("#EXT-X-DISCONTINUITY-SEQUENCE:6"))
        #expect(!result.manifest.contains("ad.ts"))
    }

    @Test("直播清单：删中间段会让序号错位 → 整体放弃")
    func fallsBackInsteadOfDeletingMiddleLiveSegment() throws {
        let manifest = "#EXTM3U\n"
            + "#EXT-X-MEDIA-SEQUENCE:100\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/ad.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.fallback)
        #expect(!result.changed)
        #expect(result.manifest == manifest)
    }

    @Test("`#EXT-X-DISCONTINUITY-SEQUENCE` 不算边界（不会被当成「片段前的 DISCONTINUITY」）")
    func doesNotTreatDiscontinuitySequenceAsBoundary() throws {
        let manifest = "#EXTM3U\n"
            + "#EXT-X-MEDIA-SEQUENCE:100\n"
            + "#EXT-X-DISCONTINUITY-SEQUENCE:5\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/ad.ts\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.changed)
        // 被删的片段不是「DISCONTINUITY 起头」的，所以这个序号不该被推进
        #expect(result.manifest.contains("#EXT-X-DISCONTINUITY-SEQUENCE:5"))
    }

    @Test("边界标签跨过 #EXT-X-KEY 也算同一个片段的前缀（不重复计、KEY 保留）")
    func removesBoundaryAcrossKeyTagWithoutDoubleCounting() throws {
        let manifest = "#EXTM3U\n"
            + "#EXT-X-MEDIA-SEQUENCE:100\n"
            + "#EXT-X-DISCONTINUITY-SEQUENCE:5\n"
            + "#EXT-X-DISCONTINUITY\n"
            + "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/ad.ts\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.changed)
        #expect(result.manifest.contains("#EXT-X-DISCONTINUITY-SEQUENCE:6"))
        #expect(!result.manifest.contains("#EXT-X-DISCONTINUITY\n"))
        #expect(result.manifest.contains("#EXT-X-KEY:METHOD=AES-128"))
    }

    @Test("字节范围清单：整体放弃（片段边界语义不同）")
    func fallsBackForByteRangePlaylist() throws {
        let manifest = "#EXTM3U\n"
            + "#EXT-X-BYTERANGE:1000@0\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/media.ts\n"
            + "#EXT-X-BYTERANGE:1000\n"
            + "#EXTINF:8.0,\nmedia.ts\n"
            + "#EXT-X-ENDLIST\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.fallback)
        #expect(result.manifest == manifest)
    }

    @Test("删除总时长超过 90 秒：整体放弃")
    func fallsBackWhenRemovedDurationExceedsSafetyLimit() throws {
        let manifest = "#EXTM3U\n"
            + "#EXTINF:91.0,\nhttps://ads.example.com/long.ts\n"
            + "#EXTINF:120.0,\nmain-1.ts\n"
            + "#EXTINF:120.0,\nmain-2.ts\n"
            + "#EXT-X-ENDLIST\n"
        let rule = try HLSManifestCleaner.Rule(hostSuffixes: ["ads.example.com"], minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [rule])

        #expect(result.fallback)
        #expect(result.manifest == manifest)
    }

    @Test("多条规则命中时：算在**第一条**头上（顺序敏感）")
    func attributesEachRemovedSegmentToTheFirstMatchingRule() throws {
        let manifest = "#EXTM3U\n"
            + "#EXTINF:7.0,\nhttps://ads.example.com/ad.ts\n"
            + "#EXTINF:8.0,\nmain-1.ts\n"
            + "#EXTINF:8.0,\nmain-2.ts\n"
            + "#EXTINF:8.0,\nmain-3.ts\n"
            + "#EXT-X-ENDLIST\n"
        let first = try HLSManifestCleaner.Rule(id: "rule-first",
                                                hostSuffixes: ["ads.example.com"],
                                                minimumSignals: 1)
        let second = try HLSManifestCleaner.Rule(id: "rule-second",
                                                 segmentUrlPatterns: ["/ad\\.ts$"],
                                                 minimumSignals: 1)

        let result = HLSManifestCleaner.clean(baseURL: baseURL, manifest: manifest, rules: [first, second])

        #expect(result.changed)
        #expect(result.ruleCounts["rule-first"] == 1)
        #expect(result.ruleCounts["rule-second"] == nil)
        // 明细里也要能看出是哪条规则、删了哪一段
        #expect(result.removedSegmentDetails.count == 1)
        #expect(result.removedSegmentDetails.first?.ruleID == "rule-first")
        #expect(result.removedSegmentDetails.first?.adDomain == "ads.example.com")
        #expect(result.removedSegmentDetails.first?.startSeconds == 0)
    }
}
