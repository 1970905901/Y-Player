import CatVodCore
import CatVodPlayer
@testable import CatVodUI
import Foundation
import Testing

/// 诊断报告（M17P1）：脱敏、空值写法、段落与正文。
@Suite("诊断报告")
struct DiagnosticsReportTests {
    private func sample() -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.1.0 (1)",
            systemVersion: "Version 26.5 (Build 23F79)",
            interfaceKind: "JS 源（js2p）",
            interfaceAddress: "https://9280.kstore.vip/cat/index.js",
            interfaceDigest: "e5b9b774af06…",
            interfaceCachedAt: "2026-10-10 09:10:02",
            interfaceCacheSize: "6.2 MB",
            engine: "MPV",
            decoder: "硬件解码",
            mpvAvailability: "libmpv=可用，Libavcodec=可用",
            downloads: "共 3 条：下载中 1 · 排队 1 · 暂停 0 · 完成 1 · 失败 0",
            hostStatus: "运行中（http://127.0.0.1:9988，55 个站点）",
            hostTail: ["[info] host ready", "[warn] slow"],
            storageFailures: ["本地库打开失败：disk full"]
        )
    }

    private func blank() -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "",
            systemVersion: "",
            interfaceKind: "",
            interfaceAddress: "",
            interfaceDigest: "",
            interfaceCachedAt: "",
            interfaceCacheSize: "",
            engine: "",
            decoder: "",
            mpvAvailability: "",
            downloads: "",
            hostStatus: "",
            hostTail: [],
            storageFailures: []
        )
    }

    @Test("地址脱敏：查询串整个抹掉")
    func redactsQuery() {
        let redacted = DiagnosticsReport.redactAddress("https://9280.kstore.vip/cat/index.js.md5?token=secret&u=1")
        #expect(redacted == "https://9280.kstore.vip/cat/index.js.md5")
        #expect(!redacted.contains("secret"))
    }

    @Test("不是 http 地址就不给原文（内联 JSON 配置里什么都有）")
    func hidesNonHTTPAddress() {
        let inline = #"{"sites":[{"api":"https://secret.example/token=abc"}]}"#
        let redacted = DiagnosticsReport.redactAddress(inline)
        #expect(redacted.hasPrefix("（"))
        #expect(!redacted.contains("secret"))
        #expect(DiagnosticsReport.redactAddress("   ") == "—")
    }

    @Test("空值统一写「—」，空列表写「（无）」")
    func blanksBecomeDash() {
        let text = blank().text
        #expect(text.contains("App：—"))
        #expect(text.contains("摘要：—"))
        #expect(text.contains("内核可用性：—"))
        #expect(text.contains("最近输出：（无）"))
        #expect(text.contains("【失败记录】\n（无）"))
    }

    @Test("正文分段落，值原样带出、宿主输出缩进两格")
    func textHasSections() {
        let text = sample().text
        for header in ["【接口】", "【播放】", "【下载】", "【宿主】", "【失败记录】"] {
            #expect(text.contains(header))
        }
        #expect(text.hasPrefix("Y-Player 诊断报告\n"))
        #expect(text.contains("App：0.1.0 (1)"))
        #expect(text.contains("摘要：e5b9b774af06…"))
        #expect(text.contains("拉取时间：2026-10-10 09:10:02"))
        #expect(text.contains("缓存大小：6.2 MB"))
        #expect(text.contains("内核：MPV"))
        #expect(text.contains("  [info] host ready"))
        #expect(text.contains("- 本地库打开失败：disk full"))
    }

    @Test("时间戳固定形状（时区本地，格式不跟随区域）")
    func timestampIsFixed() {
        let stamp = DiagnosticsReport.timestamp(Date(timeIntervalSince1970: 0))
        #expect(stamp.count == 19)
        #expect(stamp.filter { $0 == "-" }.count == 2)
        #expect(stamp.filter { $0 == ":" }.count == 2)
    }

    @Test("最近播放：非空项才成行，值就是内核报的那几个")
    func playbackRowsFromStats() {
        let full = PlaybackStats(rawValues: [
            "video-params/w": "3840",
            "video-params/h": "2160",
            "video-format": "hevc",
            "video-params/pixelformat": "yuv420p10",
            "container-fps": "23.976",
            "video-params/primaries": "bt.2020",
            "video-params/gamma": "pq",
            "hwdec-current": "videotoolbox",
            "video-bitrate": "12400000",
            "frame-drop-count": "0",
            "decoder-frame-drop-count": "0",
        ])
        // 一项一断言：红了就知道是哪一项的输入→输出不对（比「行数对不上」好排查得多）
        #expect(full.resolutionText == "3840×2160")
        #expect(full.codecText == "hevc · yuv420p10")
        #expect(full.fpsText == "23.976")
        #expect(full.dynamicRangeText == "HDR · PQ (ST2084) · BT.2020")
        #expect(full.decodeText == "硬件解码（VideoToolbox）")
        #expect(full.bitrateText == "12.4 Mbps")
        #expect(full.dropText == "无丢帧")
        #expect(!full.isEmpty)

        let rows = DiagnosticsReport.playbackRows(from: full)
        #expect(rows.map(\.title) == ["画面", "编码", "帧率", "色彩", "解码", "码率", "丢帧"])
        #expect(rows.first == DiagnosticsReport.PlaybackRow(title: "画面", value: "3840×2160"))
        #expect(rows.last == DiagnosticsReport.PlaybackRow(title: "丢帧", value: "无丢帧"))

        // 只读到分辨率时，其余空项不出现（与播放页那一块同一口径）——
        // 「丢帧」尤其重要：那两个计数**没读到**时不许说「无丢帧」（那是句假话）。
        let partial = PlaybackStats(rawValues: ["video-params/w": "1920", "video-params/h": "1080"])
        #expect(partial.dropText.isEmpty)
        #expect(DiagnosticsReport.playbackRows(from: partial).map(\.title) == ["画面"])

        #expect(DiagnosticsReport.playbackRows(from: nil).isEmpty)
        #expect(DiagnosticsReport.playbackRows(from: PlaybackStats()).isEmpty)
    }

    @Test("正文里的「最近播放」段：没有就明说")
    func playbackSectionInText() {
        #expect(blank().text.contains("【最近播放】\n（这次启动还没播过）"))

        var report = sample()
        report.playbackRows = [DiagnosticsReport.PlaybackRow(title: "色彩", value: "HDR · PQ (ST2084) · BT.2020")]
        #expect(report.text.contains("【最近播放】\n色彩：HDR · PQ (ST2084) · BT.2020"))
    }
}

/// 采集那一半（`AppModel.diagnosticsReport`）：内联配置下也该给出一份能看的报告。
@Suite("诊断报告接线")
@MainActor
struct DiagnosticsWiringTests {
    @Test("采到的报告：内联配置不留原文、下载计数从 0 起、播放设置是真值")
    func reportFromModel() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        let report = await fixture.model.diagnosticsReport(now: Date(timeIntervalSince1970: 1_700_000_000))
        // 内联 JSON 不是 http 地址：报告里只能看到一句说明，绝不能把配置正文贴出去
        #expect(report.interfaceAddress.hasPrefix("（"))
        #expect(!report.interfaceAddress.contains("sites"))
        #expect(report.interfaceKind == "JSON 配置")
        #expect(report.downloads == "共 0 条")
        #expect(report.engine == fixture.model.playbackSettings.engine.displayName)
        #expect(report.text.contains("【接口】"))
    }

    @Test("下载计数：入队后按状态分类")
    func downloadSummaryCounts() async throws {
        let fixture = try AppModelFixture(downloadTransport: nil)
        defer { fixture.tearDown() }
        await fixture.load()

        await fixture.model.enqueueDownloads(
            [
                DownloadRequest(episode: "第 1 集", line: "线路一", url: "https://cdn.example/1.mp4"),
                DownloadRequest(episode: "第 2 集", line: "线路一", url: "https://cdn.example/2.mp4"),
            ],
            siteKey: "a",
            title: "某剧"
        )
        #expect(fixture.model.downloadSummaryText.contains("共 2 条"))
        #expect(fixture.model.downloadSummaryText.contains("排队 2"))
    }

    @Test("播放页回传的播放信息会进报告（M17P2）")
    func playbackStatsReachReport() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        #expect(fixture.model.lastPlaybackStats == nil)

        let stats = PlaybackStats(rawValues: [
            "video-params/w": "3840",
            "video-params/h": "2160",
            "video-format": "hevc",
        ])
        fixture.model.notePlaybackStats(stats)

        let report = await fixture.model.diagnosticsReport(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(report.playbackRows.map(\.title) == ["画面", "编码"])
        #expect(report.text.contains("编码：hevc"))
    }
}
