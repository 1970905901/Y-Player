@testable import CatVodNet
import Foundation
import Testing

@Suite("HTTP 基础类型")
struct HTTPTransportTests {
    @Test("响应 2xx 判定")
    func successRange() {
        #expect(HTTPResponse(status: 200).isSuccess)
        #expect(HTTPResponse(status: 204).isSuccess)
        #expect(!HTTPResponse(status: 301).isSuccess)
        #expect(!HTTPResponse(status: 500).isSuccess)
    }

    @Test("文本体 UTF-8 解码，失败回退 Latin-1")
    func textDecoding() {
        let utf8 = String(data: Data("猫源".utf8), encoding: .utf8) ?? ""
        let response = HTTPResponse(status: 200, body: Data(utf8.utf8))
        #expect(response.text == "猫源")

        let latin = HTTPResponse(status: 200, body: Data([0xE9]))
        #expect(latin.text == "é")
    }

    @Test("header 合并：后者覆盖前者")
    func headerMerge() {
        let merged = HTTPHeaderMerger.merge([
            ["User-Agent": "A", "Referer": "R1"],
            ["User-Agent": "B"],
        ])
        #expect(merged["User-Agent"] == "B")
        #expect(merged["Referer"] == "R1")
    }

    @Test("JSON 请求自动补 Content-Type")
    func jsonRequestHeaders() throws {
        let url = try #require(URL(string: "http://127.0.0.1:9978/spider/home"))
        let request = HTTPRequest.json(url: url, body: Data("{}".utf8))
        #expect(request.method == .post)
        #expect(request.headers["Content-Type"] == "application/json; charset=utf-8")
    }
}
