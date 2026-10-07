import CatVodCore
import CatVodNet
import Foundation
import Testing

@testable import CatVodSource

@Suite("站点 API 地址构造（对齐 SiteApi.java）")
struct ApiURLBuilderTests {
    private func site(
        type: Int,
        api: String = "https://api.example.com/vod",
        ext: AnyJSONValue = .null,
        playUrl: String = ""
    ) -> Site {
        Site(key: "demo", name: "演示", type: type, api: api, ext: ext, playUrl: playUrl)
    }

    private func query(of request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test("ac 取值：类型 0 为 videolist，其余为 detail")
    func acMapping() {
        #expect(ApiURLBuilder.ac(for: site(type: 0)) == "videolist")
        #expect(ApiURLBuilder.ac(for: site(type: 1)) == "detail")
        #expect(ApiURLBuilder.ac(for: site(type: 2)) == "detail")
        #expect(ApiURLBuilder.ac(for: site(type: 4)) == "detail")
    }

    @Test("首页：类型 0/1/2 无参数，类型 4 带 filter=true")
    func homeRequest() throws {
        let plain = try ApiURLBuilder.homeRequest(site: site(type: 1))
        #expect(query(of: plain).isEmpty)

        let type4 = try ApiURLBuilder.homeRequest(site: site(type: 4))
        #expect(query(of: type4)["filter"] == "true")
    }

    @Test("分类：ac + t + pg；类型 1 追加 f，类型 4 追加 ext(base64)")
    func categoryRequest() throws {
        let type0 = try ApiURLBuilder.categoryRequest(site: site(type: 0), categoryID: "20", page: 2)
        let type0Query = query(of: type0)
        #expect(type0Query["ac"] == "videolist")
        #expect(type0Query["t"] == "20")
        #expect(type0Query["pg"] == "2")
        #expect(type0Query["f"] == nil)

        let type1 = try ApiURLBuilder.categoryRequest(
            site: site(type: 1),
            categoryID: "20",
            page: 1,
            extend: ["area": "大陆"]
        )
        #expect(query(of: type1)["f"] == #"{"area":"大陆"}"#)

        let type4 = try ApiURLBuilder.categoryRequest(
            site: site(type: 4),
            categoryID: "20",
            page: 1,
            extend: ["area": "大陆"]
        )
        let encoded = query(of: type4)["ext"] ?? ""
        #expect(Base64URL.decode(encoded) == #"{"area":"大陆"}"#)
        #expect(!encoded.contains("="))
    }

    @Test("详情：ac + ids")
    func detailRequest() throws {
        let parameters = query(of: try ApiURLBuilder.detailRequest(site: site(type: 1), vodID: "1001"))
        #expect(parameters["ac"] == "detail")
        #expect(parameters["ids"] == "1001")
    }

    @Test("搜索：wd + quick + extend；pg 仅在 page != 1 时携带")
    func searchRequest() throws {
        let first = query(of: try ApiURLBuilder.searchRequest(site: site(type: 1), keyword: "海贼", page: 1, quick: true))
        #expect(first["wd"] == "海贼")
        #expect(first["quick"] == "true")
        #expect(first["pg"] == nil)

        let second = query(of: try ApiURLBuilder.searchRequest(site: site(type: 1), keyword: "海贼", page: 3, quick: false))
        #expect(second["pg"] == "3")
        #expect(second["quick"] == "false")
    }

    @Test("ext 非空时追加 extend；超长改用 POST 表单")
    func extendHandling() throws {
        let short = try ApiURLBuilder.homeRequest(
            site: site(type: 1, ext: .object(["host": .string("https://x.example.com")]))
        )
        #expect(short.method == .get)
        #expect(query(of: short)["extend"] == #"{"host":"https://x.example.com"}"#)

        let longText = String(repeating: "a", count: 1200)
        let long = try ApiURLBuilder.homeRequest(site: site(type: 1, ext: .string(longText)))
        #expect(long.method == .post)
        let body = String(data: long.body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("extend="))
    }

    @Test("补图仅对类型 0/1/2 生效，且 ids 用逗号连接")
    func pictureRequest() throws {
        let request = try #require(try ApiURLBuilder.pictureRequest(site: site(type: 1), ids: ["1", "2"]))
        #expect(query(of: request)["ids"] == "1,2")

        #expect(try ApiURLBuilder.pictureRequest(site: site(type: 3), ids: ["1"]) == nil)
        #expect(try ApiURLBuilder.pictureRequest(site: site(type: 4), ids: ["1"]) == nil)
    }
}
