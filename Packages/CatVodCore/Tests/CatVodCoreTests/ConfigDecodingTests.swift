import CatVodCore
import Foundation
import Testing

/// 读取 fixtures（与 Package.swift 的 `.copy("Fixtures")` 对应）。
func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "缺少 fixture: \(name).json"
    )
    return try Data(contentsOf: url)
}

func decodeConfig(_ name: String) throws -> SourceConfig {
    try JSONDecoder().decode(SourceConfig.self, from: fixtureData(name))
}

@Suite("配置解码：上游文档示例")
struct ConfigDecodingTests {
    @Test("完整示例逐字段解码")
    func fullConfig() throws {
        let config = try decodeConfig("full-config")
        #expect(config.spider == "./spider.jar")
        #expect(config.notice == "测试配置")
        #expect(config.wallpaper == "./wallpaper.jpg")
        #expect(config.logo == "./logo.png")
        #expect(config.home == "demo")
        #expect(config.parse == "演示解析")
        #expect(config.sites.count == 5)
        #expect(config.parses.count == 3)
        #expect(config.lives.count == 1)
        #expect(config.doh.first?.ips == ["8.8.8.8"])
        #expect(config.proxy.first?.urls == ["socks5://127.0.0.1:7897"])
        #expect(config.headers.first?.header["User-Agent"] == "Mozilla/5.0")
        #expect(config.rules.first?.regex == ["\\.m3u8"])
        #expect(config.ads == ["ad.example.com"])
        #expect(config.flags == ["需要解析"])
        #expect(!config.isErrorResponse)
    }

    @Test("站点类型分发与可用性")
    func siteKindAndAvailability() throws {
        let config = try decodeConfig("full-config")

        let cat = try #require(config.site(forKey: "cat"))
        #expect(cat.kind == .spider)
        #expect(cat.isCatSpiderHTTP)
        #expect(cat.spiderRuntimeKind == .catSpiderHTTP)
        #expect(cat.availability.isAvailable)
        #expect(cat.timeout == 20)
        #expect(cat.categories == ["电影", "剧集"])
        #expect(cat.style?.resolvedRatio == 1.33)

        let jsonSite = try #require(config.site(forKey: "cmsjson"))
        #expect(jsonSite.kind == .jsonApi)

        let xmlSite = try #require(config.site(forKey: "cmsxml"))
        #expect(xmlSite.kind == .xmlApi)

        let jsSite = try #require(config.site(forKey: "jsdemo"))
        #expect(jsSite.spiderRuntimeKind == .javaScript)

        // csp_*.jar 需要 JVM，Apple 平台不支持，必须给出明确原因。
        let jarSite = try #require(config.site(forKey: "demo"))
        #expect(jarSite.spiderRuntimeKind == .jarJava)
        #expect(!jarSite.availability.isAvailable)
        #expect(jarSite.availability.reason?.contains("JVM") == true)
    }

    @Test("CatSpider 判定：Loader 分派严格要求 /spider/，端点归类允许 /spider 结尾")
    func catSpiderPredicates() {
        let loaderShape = Site(key: "a", name: "A", type: 3, api: "http://127.0.0.1:9988/spider/cat")
        #expect(loaderShape.isCatSpiderHTTP)
        #expect(loaderShape.isCatSpiderEndpoint)
        #expect(loaderShape.spiderRuntimeKind == .catSpiderHTTP)

        // 与 CatSpider.java 的 matches() 一致：裸 /spider 不交给 Loader 分派，
        // 但归类/可用性检查必须能识别，避免误报“无法识别的 api”。
        let bareShape = Site(key: "b", name: "B", type: 3, api: "http://127.0.0.1:9988/spider")
        #expect(!bareShape.isCatSpiderHTTP)
        #expect(bareShape.isCatSpiderEndpoint)
        #expect(bareShape.spiderRuntimeKind == .catSpiderHTTP)
        #expect(bareShape.availability.isAvailable)
    }

    @Test("默认站点/解析器回退与校验告警")
    func resolution() throws {
        let config = try decodeConfig("full-config")
        // home=demo 唯一匹配的站点不可用，应回退到第一个可用站点。
        #expect(config.resolvedHomeSite?.key == "cmsjson")
        #expect(config.resolvedParser?.name == "演示解析")
        #expect(config.usableSites.count == 4)
        #expect(config.usableParsers.count == 2)

        let warnings = config.validationWarnings
        #expect(warnings.contains { $0.contains("不可用") })
    }

    @Test("JAR 解析器不可用并给出原因")
    func parserAvailability() throws {
        let config = try decodeConfig("full-config")
        let jarParser = try #require(config.parser(named: "JAR解析"))
        #expect(jarParser.kind == .jarJson)
        #expect(!jarParser.availability.isAvailable)
        #expect(jarParser.availability.reason?.contains("JVM") == true)
    }
}
