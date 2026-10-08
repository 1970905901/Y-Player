import CatVodCore
import Foundation
import Testing

@Suite("直播 EPG 地址的本地覆盖（M07d-1）")
struct LiveEPGOverrideTests {
    /// 造一份「已经过解析器」的源：频道继承源级设置（含 EPG 模板展开），与生产路径同一口径。
    private func makeSource(epg: String, tvgID: String = "cctv1") throws -> LiveSource {
        let json = """
        {"name":"演示直播","url":"http://list/epg.txt","epg":"\(epg)","groups":[
          {"name":"央视","channel":[{"name":"CCTV-1","urls":["http://a/1.m3u8"],"tvgId":"\(tvgID)"}]}
        ]}
        """
        var source = try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
        // 与生产路径同一口径：频道继承源级设置（含 EPG 模板展开）。
        // 先拷一份再传给 `inherit`：`source` 正在被写，**不能**既读它整值又改它元素。
        let template = source
        for groupIndex in source.groups.indices {
            for channelIndex in source.groups[groupIndex].channels.indices {
                source.groups[groupIndex].channels[channelIndex].inherit(from: template)
            }
        }
        return source
    }

    @Test("没填地址就是没覆盖：源原样返回，也不动频道")
    func emptyOverride() throws {
        let source = try makeSource(epg: "http://src/epg?ch={id}&date={date}")
        let override = LiveEPGOverride()
        #expect(override.isEmpty)
        #expect(!override.isGlobalXML)

        let applied = override.applying(to: source)
        #expect(applied.epg == source.epg)
        #expect(applied.groups[0].channels[0].epg == source.groups[0].channels[0].epg)
        #expect(applied.groups[0].channels[0].epg == "http://src/epg?ch=cctv1&date={date}")
    }

    @Test("模板覆盖：顶掉源自己的接口地址，频道按覆盖模板重新展开")
    func templateOverride() throws {
        let source = try makeSource(epg: "http://src/epg?ch={id}&date={date}")
        let override = LiveEPGOverride(url: "  http://mine/epg?id={id}&date={date}  ")
        #expect(override.url == "http://mine/epg?id={id}&date={date}")
        #expect(!override.isGlobalXML)

        let applied = override.applying(to: source)
        #expect(applied.epgAPI == "http://mine/epg?id={id}&date={date}")
        // `{id}` 用频道自己的 epgID 展开；`{date}` 留给拉取时按天替换。
        #expect(applied.groups[0].channels[0].epg == "http://mine/epg?id=cctv1&date={date}")
        // 模板形态没有「整源文件」，文件形态的地址列表是空的。
        #expect(override.fileURLs(for: source).isEmpty)
    }

    @Test("整源 XML 覆盖：频道自己的地址清空，不再逐频道请求")
    func globalXMLOverride() throws {
        let source = try makeSource(epg: "http://src/epg?ch={id}&date={date}")
        let override = LiveEPGOverride(url: "http://mine/all.xml")
        #expect(override.isGlobalXML)

        let applied = override.applying(to: source)
        #expect(applied.groups[0].channels[0].epg.isEmpty)
        #expect(applied.epgAPI == "http://mine/all.xml")
        #expect(override.fileURLs(for: source) == ["http://mine/all.xml"])
    }

    @Test("文件列表：覆盖的整源 XML 排在源自己的文件前面并去重（不带 xml/gz 字样也照样拉）")
    func fileURLs() throws {
        let source = try makeSource(epg: "http://src/a.xml.gz")
        let override = LiveEPGOverride(url: "http://mine/all.php")
        // 覆盖地址没有 `xml` / `gz` 字样 → `epgXML` 过滤不出来，所以必须由这里给出。
        #expect(source.epgXML == ["http://src/a.xml.gz"])
        #expect(override.fileURLs(for: source) == ["http://mine/all.php", "http://src/a.xml.gz"])

        // 套过覆盖的那份再传进来：不重复。
        let applied = override.applying(to: source)
        #expect(override.fileURLs(for: applied) == ["http://mine/all.php", "http://src/a.xml.gz"])

        // 模板覆盖时源自己的文件照旧要拉（上游 `getEpgXml` 读源自己的字段）。
        let template = LiveEPGOverride(url: "http://mine/epg?id={id}&date={date}")
        #expect(template.fileURLs(for: source) == ["http://src/a.xml.gz"])
    }
}
