import CatVodCore
import Foundation
import Testing

@Suite("配置解码：类型混乱的真实上游形态")
struct MessyConfigDecodingTests {
    @Test("msg 非空表示错误响应")
    func errorResponse() throws {
        let config = try decodeConfig("messy-config")
        #expect(config.isErrorResponse)
        #expect(config.msg.contains("失效"))
    }

    @Test("顶层标量字段类型不符时降级而不是整体失败")
    func lenientTopLevel() throws {
        let config = try decodeConfig("messy-config")
        #expect(config.notice == "123")
        #expect(config.home == "100")
        // 单个字符串会被包装成单元素数组
        #expect(config.hosts == ["example.com=1.2.3.4"])
        #expect(config.ads == ["ad.example.com"])
        #expect(config.flags == ["a", "2"])
    }

    @Test("数组里的非对象元素被跳过，其余站点正常解码")
    func siteArrayTolerance() throws {
        let config = try decodeConfig("messy-config")
        #expect(config.sites.count == 5)

        let ok = try #require(config.site(forKey: "ok"))
        #expect(ok.name == "42")
        #expect(ok.type == 1)
        #expect(ok.kind == .jsonApi)
        #expect(ok.searchable == 0)
        #expect(!ok.searchAvailability.isUsable)
        #expect(ok.changeable == 1)
        // timeout 非法值退回默认 15
        #expect(ok.timeout == 15)
    }

    @Test("home_page 别名、单值 categories、数值 header、字符串 ratio")
    func aliasAndCoercion() throws {
        let config = try decodeConfig("messy-config")
        let alias = try #require(config.site(forKey: "alias"))
        #expect(alias.homePage == "https://alias.example.com/home")
        #expect(alias.categories == ["电影"])
        #expect(alias.header["User-Agent"] == "2024")
        #expect(alias.style?.ratio == 2.5)
        #expect(alias.style?.kind == .oval)
        #expect(alias.style?.resolvedRatio == 2.5)
    }

    @Test("缺 key / 缺 api / 未知类型都给出可展示原因")
    func unavailableReasons() throws {
        let config = try decodeConfig("messy-config")
        let noKey = try #require(config.sites.first { $0.name == "缺少 key" })
        #expect(noKey.availability.reason == "站点缺少 key")

        let noAPI = try #require(config.site(forKey: "noapi"))
        #expect(noAPI.availability.reason == "站点缺少 api")

        let unknown = try #require(config.site(forKey: "unknowntype"))
        #expect(unknown.availability.reason?.contains("type=99") == true)

        // 可用站点只剩两个
        #expect(config.usableSites.map(\.key).sorted() == ["alias", "ok"])
    }

    @Test("解析器类型字符串与 flag 单值归一化")
    func parserCoercion() throws {
        let config = try decodeConfig("messy-config")
        let parser = try #require(config.parses.first)
        #expect(parser.type == 1)
        #expect(parser.kind == .json)
        #expect(parser.ext.flag == ["abc"])
        #expect(parser.ext.accepts(flag: "abc"))
        #expect(!parser.ext.accepts(flag: "qq"))
        // flag 为空表示适用全部线路
        #expect(ParserExt().accepts(flag: "任意"))
    }
}
