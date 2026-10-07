import CatVodCore
@testable import CatVodSource
import Foundation
import Testing

@Suite("CatSpider 响应解包（对齐 CatSpider.java#unwrap）")
struct CatSpiderResponseDecoderTests {
    @Test("data 是对象：取 data")
    func unwrapObject() throws {
        let data = Data(#"{"code":0,"data":{"class":[{"type_id":"1","type_name":"电影"}]}}"#.utf8)
        let normalized = try CatSpiderResponseDecoder.normalize(data, path: "/home")
        let result = try JSONDecoder().decode(SpiderResult.self, from: normalized)
        #expect(result.categories.count == 1)
        #expect(result.categories[0].typeID == "1")
        #expect(result.categories[0].typeName == "电影")
    }

    @Test("data 是数组：包装成 list")
    func unwrapArray() throws {
        let data = Data(#"{"code":0,"data":[{"vod_id":"1","vod_name":"示例"}]}"#.utf8)
        let normalized = try CatSpiderResponseDecoder.normalize(data, path: "/search")
        let result = try JSONDecoder().decode(SpiderResult.self, from: normalized)
        #expect(result.list.count == 1)
        #expect(result.list[0].vodName == "示例")
    }

    @Test("无 data 包装：原样解析")
    func plainObject() throws {
        let data = Data(#"{"list":[{"vod_id":"9","vod_name":"直出"}]}"#.utf8)
        let normalized = try CatSpiderResponseDecoder.normalize(data, path: "/category")
        let result = try JSONDecoder().decode(SpiderResult.self, from: normalized)
        #expect(result.list.first?.vodID == "9")
    }

    @Test("顶层数组：当作 list")
    func topLevelArray() throws {
        let data = Data(#"[{"vod_id":"2"}]"#.utf8)
        let normalized = try CatSpiderResponseDecoder.normalize(data, path: "/category")
        let result = try JSONDecoder().decode(SpiderResult.self, from: normalized)
        #expect(result.list.first?.vodID == "2")
    }

    @Test("空响应与非法 JSON 抛解码错误")
    func invalidPayload() {
        #expect(throws: CatVodError.self) {
            _ = try CatSpiderResponseDecoder.normalize(Data(), path: "/play")
        }
        #expect(throws: CatVodError.self) {
            _ = try CatSpiderResponseDecoder.normalize(Data("<html>error</html>".utf8), path: "/play")
        }
    }
}
