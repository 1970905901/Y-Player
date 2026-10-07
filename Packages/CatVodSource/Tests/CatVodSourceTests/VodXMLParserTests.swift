import CatVodCore
import CatVodNet
import Foundation
import Testing

@testable import CatVodSource

@Suite("苹果CMS XML 解析（type=0）")
struct VodXMLParserTests {
    private let sample = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="5.1">
      <list page="2" pagecount="5" pagesize="20" recordcount="100">
        <video>
          <id>1001</id>
          <name>示例影片</name>
          <type>电影</type>
          <pic>https://example.com/p.jpg</pic>
          <note>更新至2集</note>
          <year>2024</year>
          <area>大陆</area>
          <actor>演员A</actor>
          <director>导演B</director>
          <dl>
            <dd flag="主线"><![CDATA[第1集$id-1#第2集$id-2]]></dd>
            <dd flag="备用线"><![CDATA[第1集$backup-1]]></dd>
          </dl>
          <des><![CDATA[这里是简介]]></des>
        </video>
      </list>
      <class>
        <ty id="1">电影</ty>
        <ty id="2">剧集</ty>
      </class>
    </rss>
    """

    @Test("分页属性与分类解析")
    func pagingAndCategories() throws {
        let result = try #require(VodXMLParser.parse(data: Data(sample.utf8)))
        #expect(result.page == 2)
        #expect(result.pagecount == 5)
        #expect(result.total == 100)
        #expect(result.categories.map(\.typeID) == ["1", "2"])
        #expect(result.categories.map(\.typeName) == ["电影", "剧集"])
    }

    @Test("条目字段映射")
    func videoMapping() throws {
        let result = try #require(VodXMLParser.parse(data: Data(sample.utf8)))
        #expect(result.list.count == 1)
        let item = try #require(result.list.first)
        #expect(item.vodID == "1001")
        #expect(item.vodName == "示例影片")
        #expect(item.typeName == "电影")
        #expect(item.vodPic == "https://example.com/p.jpg")
        #expect(item.vodRemarks == "更新至2集")
        #expect(item.vodYear == "2024")
        #expect(item.vodArea == "大陆")
        #expect(item.vodActor == "演员A")
        #expect(item.vodDirector == "导演B")
        #expect(item.vodContent == "这里是简介")
    }

    @Test("线路与选集拼装成 $$$ / # 约定")
    func playlistAssembly() throws {
        let result = try #require(VodXMLParser.parse(data: Data(sample.utf8)))
        let item = try #require(result.list.first)
        #expect(item.vodPlayFrom == "主线$$$备用线")
        #expect(item.vodPlayURL == "第1集$id-1#第2集$id-2$$$第1集$backup-1")

        let lines = PlaylistParser.parse(playFrom: item.vodPlayFrom, playURL: item.vodPlayURL)
        #expect(lines.count == 2)
        #expect(lines[0].name == "主线")
        #expect(lines[0].episodes.map(\.url) == ["id-1", "id-2"])
        #expect(lines[1].episodes.map(\.url) == ["backup-1"])
        #expect(PlaylistParser.consistencyIssues(playFrom: item.vodPlayFrom, playURL: item.vodPlayURL).isEmpty)
    }

    @Test("非法 XML 返回 nil，不抛异常")
    func invalidXML() {
        #expect(VodXMLParser.parse(data: Data("<rss><list>".utf8)) == nil)
        #expect(VodXMLParser.parse(data: Data()) == nil)
    }
}
