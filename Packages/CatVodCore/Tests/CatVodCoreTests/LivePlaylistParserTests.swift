import CatVodCore
import Foundation
import Testing

@Suite("直播源解析：对齐上游 LiveParser（m3u / txt / json）")
struct LivePlaylistParserTests {
    private let parser = LivePlaylistParser()

    /// 构造直播源：模型字段多，一律走 JSON（与生产路径同一条，顺带覆盖解码）；
    /// 不要在模型上开十几参数的长 init —— SwiftLint `function_parameter_count` 会直接报错。
    private func makeSource(_ json: String) throws -> LiveSource {
        try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    private let m3u = """
    #EXTM3U url-tvg="https://epg.example.com/xml.gz" catchup-source="?playseek=${(b)timestamp}-${(e)timestamp}"
    #EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV-1" tvg-logo="https://logo.example.com/1.png" group-title="央视",CCTV-1 综合
    #EXTVLCOPT:http-user-agent=okhttp/4
    http://live.example.com/cctv1.m3u8
    #EXTINF:-1 group-title="卫视" tvg-chno="008",湖南卫视
    http://live.example.com/hunan.m3u8|Referer=https://x.example.com/
    #EXTINF:-1,更新时间 2026-10-07
    http://meta.example.com/ignore.m3u8
    """

    @Test("m3u：分组、属性、`|` 后的 header、设置行、元信息频道过滤与自动编号")
    func m3uPlaylist() throws {
        let source = try makeSource(#"{"name":"演示直播"}"#)
        let parsed = parser.parse(m3u, into: source)

        #expect(parsed.groups.map(\.name) == ["央视", "卫视"])
        let cctv = try #require(parsed.groups.first?.channels.first)
        #expect(cctv.name == "CCTV-1 综合")
        #expect(cctv.tvgID == "cctv1")
        #expect(cctv.tvgName == "CCTV-1")
        #expect(cctv.logo == "https://logo.example.com/1.png")
        #expect(cctv.ua == "okhttp/4")
        #expect(cctv.number == "001")
        #expect(cctv.urls == ["http://live.example.com/cctv1.m3u8"])
        // 频道没写 catchup 时用清单头里的那份（上游 `Catchup.decide(unknown, header)`）。
        #expect(cctv.catchup?.source == "?playseek=${(b)timestamp}-${(e)timestamp}")

        let hunan = try #require(parsed.groups.last?.channels.first)
        #expect(hunan.number == "008")
        #expect(hunan.header["Referer"] == "https://x.example.com/")
        // 元信息频道（`更新时间…`）不进列表。
        #expect(parsed.channelCount == 2)
        // 清单头的 EPG 写进了源级 `epg`（逗号串 → 接口/文件两类）。
        #expect(parsed.epg == "https://epg.example.com/xml.gz")
        #expect(parsed.epgXML == ["https://epg.example.com/xml.gz"])
    }

    private let txt = """
    央视,#genre#
    CCTV-1,http://live.example.com/cctv1.m3u8#http://backup.example.com/cctv1.m3u8
    CCTV-2,http://live.example.com/cctv2.m3u8
    卫视,#genre#
    湖南卫视,http://live.example.com/hunan.m3u8
    更新时间 2026-10-07,http://meta.example.com/ignore.m3u8
    """

    @Test("txt：`#genre#` 切分组、`#` 多线路、元信息过滤、跨分组连续编号")
    func txtPlaylist() throws {
        let source = try makeSource(#"{"name":"演示直播"}"#)
        let parsed = parser.parse(txt, into: source)

        #expect(parsed.groups.map(\.name) == ["央视", "卫视"])
        let cctv = try #require(parsed.groups.first?.channels.first)
        #expect(cctv.urls.count == 2)
        #expect(cctv.number == "001")
        let hunan = try #require(parsed.groups.last?.channels.first)
        #expect(hunan.number == "003")
        #expect(parsed.channelCount == 3)
    }

    @Test("txt：没有 `#genre#` 时落到默认分组（上游 `Group.create()`）")
    func txtWithoutGroups() throws {
        let source = try makeSource(#"{"name":"源"}"#)
        let parsed = parser.parse("CCTV-1,http://live.example.com/a.m3u8", into: source)
        #expect(parsed.groups.count == 1)
        #expect(parsed.groups.first?.channels.first?.urls == ["http://live.example.com/a.m3u8"])
    }

    @Test("分组名里的 `_密码`：默认拆开，`pass = true` 时不拆")
    func groupPassword() throws {
        let text = "加密组_1234,#genre#\nCCTV-1,http://live.example.com/a.m3u8"
        let source = try makeSource(#"{"name":"源"}"#)
        let split = parser.parse(text, into: source)
        #expect(split.groups.first?.name == "加密组")
        #expect(split.groups.first?.pass == "1234")
        #expect(split.groups.first?.isHidden == true)

        let plainSource = try makeSource(#"{"name":"源","pass":true}"#)
        let plain = parser.parse(text, into: plainSource)
        #expect(plain.groups.first?.name == "加密组_1234")
        #expect(plain.groups.first?.pass.isEmpty == true)
    }

    @Test("json：分组数组直接落成模型，并补编号")
    func jsonPlaylist() throws {
        let json = #"[{"name":"央视","channel":[{"name":"CCTV-1","urls":["http://live.example.com/a.m3u8"]}]}]"#
        let source = try makeSource(#"{"name":"源"}"#)
        let parsed = parser.parse(json, into: source)
        #expect(parsed.groups.map(\.name) == ["央视"])
        #expect(parsed.groups.first?.channels.first?.number == "001")
    }

    @Test("源级设置补进频道（上游 `Channel.live(Live)`：只补自己没有的）")
    func inheritsSourceSettings() throws {
        let json = #"{"name":"源","ua":"UA-source","referer":"https://site.example.com/"}"#
        let source = try makeSource(json)
        let parsed = parser.parse("#EXTM3U\n#EXTINF:-1,CH\nhttp://live.example.com/a.m3u8", into: source)
        let channel = try #require(parsed.groups.first?.channels.first)
        #expect(channel.ua == "UA-source")
        #expect(channel.referer == "https://site.example.com/")
        #expect(channel.requestHeaders()["User-Agent"] == "UA-source")
    }

    @Test("源级 `epg` 接口模板展开到频道（上游 `Channel.live(Live)`：`{id}`/`{name}`，M07c）")
    func inheritsEpgTemplate() throws {
        let source = try makeSource(#"{"name":"源","epg":"https://epg.example.com/{id}?ch={name}&date={date}"}"#)
        let parsed = parser.parse(
            "#EXTM3U\n#EXTINF:-1 tvg-id=\"cctv1\" tvg-name=\"CCTV1\",CCTV-1 综合\nhttp://live.example.com/a.m3u8",
            into: source
        )
        let channel = try #require(parsed.groups.first?.channels.first)
        // `{date}` 留着不动：拉取时按「昨天/今天/明天」替换（`LiveEPGRepository.load(channel:source:)`）。
        #expect(channel.epg == "https://epg.example.com/cctv1?ch=CCTV1&date={date}")

        // 没有 `tvg-id`/`tvg-name` 时 `{id}`/`{name}` 落到频道名（`epgID` 的三级回落）。
        let plain = parser.parse(
            "#EXTM3U\n#EXTINF:-1,CCTV-2 财经\nhttp://live.example.com/b.m3u8",
            into: source
        )
        #expect(plain.groups.first?.channels.first?.epg == "https://epg.example.com/CCTV-2 财经?ch=CCTV-2 财经&date={date}")
    }

    @Test("形态判定：m3u / json 数组 / 其余按 txt")
    func detection() {
        #expect(LivePlaylistParser.looksLikeM3U("#EXTM3U\n#EXTINF:-1,A\nhttp://a/x.m3u8"))
        #expect(!LivePlaylistParser.looksLikeM3U("央视,#genre#\nCCTV-1,http://a/x.m3u8"))
        #expect(LivePlaylistParser.isJSONArray(#"[{"name":"A"}]"#))
        #expect(!LivePlaylistParser.isJSONArray(#"{"name":"A"}"#))
        #expect(!LivePlaylistParser.isJSONArray("央视,#genre#"))
    }
}
