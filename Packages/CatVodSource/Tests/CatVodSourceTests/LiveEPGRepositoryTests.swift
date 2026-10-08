import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

@Suite("EPG 加载：取节目单文件 → XMLTV 解析（M07b）")
struct LiveEPGRepositoryTests {
    private let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="cctv1"><display-name>CCTV-1 综合</display-name></channel>
      <programme start="20261007190000 +0800" stop="20261007193000 +0800" channel="cctv1"><title>新闻联播</title></programme>
    </tv>
    """

    /// 同一份 XML 的 gzip 版本（`Tools/out/make_epg_fixture.py` 生成）：两种头形态都要能解。
    /// 换行会被 `Data(base64Encoded:options:.ignoreUnknownCharacters)` 忽略，所以直接分行写。
    private let gzipPlain = """
    H4sIAAAAAAACCl2QsU7DMBCG9zzF6VYUYhcJimS7Q6U+QWG3EpNacuzIOUUtG1vHCiF4CiT28joUeAuStKpavN19
    d7++s5gsKwetiY0NXiK/ZAjG56GwvpR4N5+lY5yoRFALpfEmagoxtf4hpF5XRuKqdnplIqoEQOQL7b1xYAuJeU4t
    H9odKGzTzw07ajqd36ccvrefX5u1yM5Yn5IdYoaijqGMuqoMNKQjSRyx0TVn7Ibfsu7BBRuzTrmhUJ+yqxN2iPun
    RJacAaf7Mx8XqHavH79v25+nl93zu8gGurc5GnS/kFGrkj/o8XlRMwEAAA==
    """

    private let gzipNamed = """
    H4sICAAAAAAC/2VwZy54bWwAXZCxTsMwEIb3PMXpVhRiFwmKZLtDpT5BYbcSk1py7Mg5RS0bW8cKIXgKJPbyOhR4
    C5K0qlq83X13v76zmCwrB62JjQ1eIr9kCMbnobC+lHg3n6VjnKhEUAul8SZqCjG1/iGkXldG4qp2emUiqgRA5Avt
    vXFgC4l5Ti0f2h0obNPPDTtqOp3fpxy+t59fm7XIzlifkh1ihqKOoYy6qgw0pCNJHLHRNWfsht+y7sEFG7NOuaFQ
    n7KrE3aI+6dElpwBp/szHxeodq8fv2/bn6eX3fO7yAa6tzkadL+QUauSP+jxeVEzAQAA
    """

    private func makeSource(_ json: String) throws -> LiveSource {
        try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    /// 直播源模型字段多，一律走 JSON 构造（与生产路径同一条）。
    private func makeSource(
        epg: String,
        url: String = "https://live.example.com/list.m3u8"
    ) throws -> LiveSource {
        let json = #"{"name":"演示直播","url":"\#(url)","timeZone":"Asia/Shanghai","ua":"UA-live","epg":"\#(epg)"}"#
        return try makeSource(json)
    }

    @Test("正常：相对地址按直播源地址解析，请求带源级 header")
    func loadsXML() async throws {
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(xml.utf8)))
        let guide = try await LiveEPGRepository(transport: recorder).load(makeSource(epg: "epg/cctv.xml"))

        #expect(guide.channelNames["cctv1"] == "CCTV-1 综合")
        #expect(guide.displayName(for: "cctv1") == "CCTV-1 综合")
        #expect(guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "新闻联播")

        let request = await recorder.firstRequest()
        #expect(request?.url.absoluteString == "https://live.example.com/epg/cctv.xml")
        #expect(request?.headers["User-Agent"] == "UA-live")
    }

    @Test("`.xml.gz`：按魔数解压（FLG=0 与带 FNAME 头两种都要能解）")
    func loadsGzip() async throws {
        for (label, base64) in [("FLG=0", gzipPlain), ("FNAME", gzipNamed)] {
            let body = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
            let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: body))
            let guide = try await LiveEPGRepository(transport: recorder).load(makeSource(epg: "epg/cctv.xml.gz"))
            let title = guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title
            #expect(title == "新闻联播", "\(label) 头形态解压失败")
        }
    }

    @Test("多地址：坏地址不影响已拿到的节目单；全坏才抛错")
    func partialFailure() async throws {
        let bad = HTTPResponse(status: 500, body: Data("<html>oops</html>".utf8))
        let good = HTTPResponse(status: 200, body: Data(xml.utf8))
        let mixed = RoutingRecorder(responses: [
            "https://live.example.com/good.xml": good,
            "https://live.example.com/bad.xml": bad,
        ])
        let guide = try await LiveEPGRepository(transport: mixed).load(makeSource(epg: "good.xml, bad.xml"))
        #expect(guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.count == 1)

        // 两个地址都坏 → 抛第一个错误（这里是 500 的 network）。
        let broken = RoutingRecorder(responses: ["https://live.example.com/bad.xml": bad])
        do {
            _ = try await LiveEPGRepository(transport: broken).load(makeSource(epg: "bad.xml,bad.xml"))
            Issue.record("全坏应当抛错")
        } catch let error as CatVodError {
            guard case .network = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
    }

    @Test("没有可用地址：epg 为空 / 只配 x-tvg 接口 → unsupported，且不发请求")
    func unsupportedSources() async throws {
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(xml.utf8)))

        do {
            _ = try await LiveEPGRepository(transport: recorder).load(makeSource(epg: ""))
            Issue.record("epg 为空应当明确拒绝")
        } catch let error as CatVodError {
            #expect(error.errorDescription?.contains("epg") == true)
        }

        do {
            let tvg = try makeSource(epg: "https://epg.example.com/api?ch={name}&date={date}")
            _ = try await LiveEPGRepository(transport: recorder).load(tvg)
            Issue.record("x-tvg 接口本轮未支持，应当明确拒绝")
        } catch let error as CatVodError {
            #expect(error.errorDescription?.contains("x-tvg") == true)
        }

        let count = await recorder.requests.count
        #expect(count == 0)
    }

    @Test("坏响应：非 2xx → network；不是 XMLTV → parseFailed；gzip 坏数据 → parseFailed")
    func failures() async {
        let notFound = ParseRequestRecorder(response: HTTPResponse(status: 404, body: Data("<html>404</html>".utf8)))
        await expectFailure(.network, from: notFound, epg: "epg/cctv.xml")

        let html = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data("<html>登录页</html>".utf8)))
        await expectFailure(.parseFailed, from: html, epg: "epg/cctv.xml")

        // 有 gzip 魔数但 DEFLATE 数据是垃圾 → 解压失败（不能当成空节目单）。
        var brokenGzip = Data([0x1F, 0x8B, 0x08, 0x00])
        brokenGzip.append(Data(repeating: 0x00, count: 6))
        brokenGzip.append(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]))
        let gzip = ParseRequestRecorder(response: HTTPResponse(status: 200, body: brokenGzip))
        await expectFailure(.parseFailed, from: gzip, epg: "epg/cctv.xml.gz")

        // 直播源地址本身非法 → 相对地址解析不出来。
        let broken = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(xml.utf8)))
        await expectFailure(.parseFailed, from: broken, epg: "epg/cctv.xml", url: "not a url")
    }

    @Test("gzip 工具本身：非 gzip 数据不解压，也不误判")
    func gzipDetection() {
        #expect(!GZipDecoder.looksLikeGzip(Data()))
        #expect(!GZipDecoder.looksLikeGzip(Data("<?xml".utf8)))
        #expect(GZipDecoder.decode(Data("not gzip".utf8)) == nil)
    }

    /// 断言某个响应必然导致指定类型的 ``CatVodError``。
    private func expectFailure(
        _ kind: FailureKind,
        from recorder: ParseRequestRecorder,
        epg: String,
        url: String = "https://live.example.com/list.m3u8"
    ) async {
        do {
            _ = try await LiveEPGRepository(transport: recorder).load(makeSource(epg: epg, url: url))
            Issue.record("应当失败：\(epg)")
        } catch let error as CatVodError {
            switch (kind, error) {
            case (.network, .network), (.parseFailed, .parseFailed):
                break
            default:
                Issue.record("错误类型不对：\(error)")
            }
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    /// 期望的错误类型（把 `CatVodError` 的模式匹配收在一处，避免每个用例写一遍 `guard case`）。
    private enum FailureKind {
        case network
        case parseFailed
    }
}

@Suite("EPG 接口（x-tvg）：逐频道 × 昨天 / 今天 / 明天（M07c）")
struct LiveEPGInterfaceTests {
    /// 与下面 `makeSource` 里的 `timeZone` 保持一致。
    private var zone: TimeZone {
        EPGTimeParser.timeZone(named: "Asia/Shanghai")
    }

    private func makeSource() throws -> LiveSource {
        let json = #"{"name":"演示直播","url":"https://live.example.com/list.m3u8","timeZone":"Asia/Shanghai","ua":"UA-live"}"#
        return try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    /// 频道模型字段多，一律走 JSON（与生产路径同一条）。
    private func makeChannel(_ json: String) throws -> LiveChannel {
        try JSONDecoder().decode(LiveChannel.self, from: Data(json.utf8))
    }

    /// 带接口模板的频道（`{name}`/`{date}` 都留着，等展开）。
    private let interfaceChannelJSON =
        #"{"name":"CCTV-1 综合","tvgId":"cctv1","tvgName":"CCTV1","epg":"https://epg.example.com/api?ch={name}&date={date}"}"#

    private func makeInterfaceChannel() throws -> LiveChannel {
        try makeChannel(interfaceChannelJSON)
    }

    private func interfaceURL(date: String) -> String {
        "https://epg.example.com/api?ch=CCTV1&date=\(date)"
    }

    private func threeDays() -> [String] {
        [-1, 0, 1].map { EPGTimeParser.dateString(dayOffset: $0, timeZone: zone) }
    }

    /// 接口返回的 XMLTV：`channel` 故意与清单里的 `tvg-id` 不同 —— 接口按频道名查，返回的 id 常常不是同一个。
    private func xmltv(date: String, title: String) -> String {
        let compact = date.replacingOccurrences(of: "-", with: "")
        return """
        <tv>
          <programme start="\(compact)190000 +0800" stop="\(compact)193000 +0800" channel="upstream-id"><title>\(title)</title></programme>
        </tv>
        """
    }

    @Test("三天各拉一次：`{date}` 按源时区替换，节目挂到频道的 `epgID` 上")
    func fetchesThreeDays() async throws {
        let dates = threeDays()
        var responses: [String: HTTPResponse] = [:]
        for date in dates {
            responses[interfaceURL(date: date)] = HTTPResponse(status: 200, body: Data(xmltv(date: date, title: "节目 \(date)").utf8))
        }
        let recorder = RoutingRecorder(responses: responses)
        let guide = try await LiveEPGRepository(transport: recorder)
            .load(channel: makeInterfaceChannel(), source: makeSource())

        #expect(guide.schedules.map(\.key) == ["cctv1", "cctv1", "cctv1"])
        #expect(guide.schedules.map(\.date) == dates)
        // 接口返回的 `channel="upstream-id"` 不参与匹配：键是频道的 `epgID`。
        #expect(guide.schedule(key: "cctv1", date: dates[1])?.programs.map(\.title) == ["节目 \(dates[1])"])
        #expect(await recorder.urls.count == 3)
    }

    @Test("`existing` 里已有的那天不再请求（上游 `noneMatch(epg -> epg.equal(date))`）")
    func skipsLoadedDays() async throws {
        let dates = threeDays()
        var responses: [String: HTTPResponse] = [:]
        for date in dates {
            responses[interfaceURL(date: date)] = HTTPResponse(status: 200, body: Data(xmltv(date: date, title: "节目 \(date)").utf8))
        }
        let existing = EPGGuide(timeZone: zone, schedules: [EPGSchedule(key: "cctv1", date: dates[1], programs: [])])
        let recorder = RoutingRecorder(responses: responses)
        let guide = try await LiveEPGRepository(transport: recorder)
            .load(channel: makeInterfaceChannel(), source: makeSource(), existing: existing)

        let urls = await recorder.urls
        #expect(urls.count == 2)
        #expect(!urls.contains(interfaceURL(date: dates[1])))
        // 已有的那天照旧留在结果里（界面把上次的 guide 传回来就能增量刷新）。
        #expect(guide.schedules.count == 3)
    }

    @Test("单天坏不影响其它天；三天全坏才抛错")
    func partialFailure() async throws {
        let dates = threeDays()
        var responses: [String: HTTPResponse] = [:]
        responses[interfaceURL(date: dates[0])] = HTTPResponse(status: 500, body: Data("oops".utf8))
        responses[interfaceURL(date: dates[1])] = HTTPResponse(status: 200, body: Data(xmltv(date: dates[1], title: "今天").utf8))
        responses[interfaceURL(date: dates[2])] = HTTPResponse(status: 500, body: Data("oops".utf8))
        let guide = try await LiveEPGRepository(transport: RoutingRecorder(responses: responses))
            .load(channel: makeInterfaceChannel(), source: makeSource())
        #expect(guide.schedules.map(\.date) == [dates[1]])

        // 全坏：把第一个错误抛出来（这里是「地址没配假响应」的 network）。
        let broken = RoutingRecorder(responses: [:])
        do {
            _ = try await LiveEPGRepository(transport: broken)
                .load(channel: makeInterfaceChannel(), source: makeSource())
            Issue.record("三天全坏应当抛错")
        } catch let error as CatVodError {
            guard case .network = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
    }

    @Test("JSON 形态：接口回 `epg_data` 也认（`EPGJSONParser`），一样挂到频道 `epgID`")
    func jsonForm() async throws {
        let dates = threeDays()
        let today = dates[1]
        let body = #"{"date":"\#(today)","epg_data":[{"title":"午间新闻","start":"12:00","end":"12:30"}]}"#
        var responses: [String: HTTPResponse] = [:]
        for date in dates {
            let payload = date == today ? body : xmltv(date: date, title: "节目")
            responses[interfaceURL(date: date)] = HTTPResponse(status: 200, body: Data(payload.utf8))
        }
        let guide = try await LiveEPGRepository(transport: RoutingRecorder(responses: responses))
            .load(channel: makeInterfaceChannel(), source: makeSource())

        let program = try #require(guide.schedule(key: "cctv1", date: today)?.programs.first)
        #expect(program.title == "午间新闻")
        #expect(program.start == "12:00")
        #expect(program.startTime == EPGTimeParser.parse(date: today, time: "12:00", timeZone: zone))
    }

    @Test("频道没有节目单地址 → unsupported，且不发请求")
    func missingAddress() async throws {
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(xmltv(date: "2026-10-07", title: "x").utf8)))
        let channel = try makeChannel(#"{"name":"CCTV-1","tvgId":"cctv1"}"#)
        do {
            _ = try await LiveEPGRepository(transport: recorder).load(channel: channel, source: makeSource())
            Issue.record("没有节目单地址应当明确拒绝")
        } catch let error as CatVodError {
            #expect(error.errorDescription?.contains("节目单地址") == true)
        }
        #expect(await recorder.requests.isEmpty)
    }

    @Test("地址不是 http（上游直接跳过）→ unsupported，且不发请求")
    func nonHTTPAddress() async throws {
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(xmltv(date: "2026-10-07", title: "x").utf8)))
        let channel = try makeChannel(#"{"name":"CCTV-1","tvgId":"cctv1","epg":"epg/{date}.xml"}"#)
        do {
            _ = try await LiveEPGRepository(transport: recorder).load(channel: channel, source: makeSource())
            Issue.record("非 http 地址应当明确拒绝")
        } catch let error as CatVodError {
            #expect(error.errorDescription?.contains("不是 http") == true)
        }
        #expect(await recorder.requests.isEmpty)
    }

    @Test("中文频道名：请求地址照样能构造（非 ASCII 交给 URL 编码）")
    func chineseChannelName() async throws {
        let date = EPGTimeParser.dateString(dayOffset: 0, timeZone: zone)
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(xmltv(date: date, title: "中文台").utf8)))
        let channel = try makeChannel(#"{"name":"CCTV-2 财经","epg":"https://epg.example.com/api?ch={name}&date={date}"}"#)
        let guide = try await LiveEPGRepository(transport: recorder).load(channel: channel, source: makeSource())

        #expect(guide.schedule(key: "CCTV-2 财经", date: date)?.programs.map(\.title) == ["中文台"])
        let request = await recorder.firstRequest()
        #expect(request?.url.absoluteString.contains("ch=CCTV-2") == true)
    }
}

/// 按地址给不同响应的假传输层：EPG 的多地址合并必须能按地址区分响应。
private actor RoutingRecorder: HTTPTransport {
    private let responses: [String: HTTPResponse]
    private(set) var urls: [String] = []

    init(responses: [String: HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        urls.append(request.url.absoluteString)
        // 没配置的地址直接抛：`throws` 不是摆设（SwiftFormat `redundantThrows` 也会盯这个）。
        guard let response = responses[request.url.absoluteString] else {
            throw CatVodError.network(status: 404, url: request.url.absoluteString, reason: "未配置该地址的假响应")
        }
        return response
    }
}
