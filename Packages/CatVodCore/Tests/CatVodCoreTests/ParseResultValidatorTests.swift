import CatVodCore
import Foundation
import Testing

@Suite("解析结果校验与取址（对齐上游 ParseJob）")
struct ParseResultValidatorTests {
    private func json(_ text: String) throws -> AnyJSONValue {
        try JSONDecoder().decode(AnyJSONValue.self, from: Data(text.utf8))
    }

    @Test("type=1 取址：先 url，为空再 data.url")
    func playURLFromJSON() throws {
        let direct = try json(#"{"url":"https://cdn.example.com/a.m3u8"}"#)
        #expect(ParseResultValidator.playURL(fromJSON: direct) == "https://cdn.example.com/a.m3u8")

        let nested = try json(#"{"url":"","data":{"url":"https://cdn.example.com/b.m3u8"}}"#)
        #expect(ParseResultValidator.playURL(fromJSON: nested) == "https://cdn.example.com/b.m3u8")

        let empty = try json(#"{"code":0,"msg":"没有地址"}"#)
        #expect(ParseResultValidator.playURL(fromJSON: empty).isEmpty)
    }

    @Test("type=1 成功判定：长度必须 > 40（40 拒绝、41 通过）")
    func acceptabilityBoundary() {
        let forty = String(repeating: "a", count: 40)
        let fortyOne = String(repeating: "a", count: 41)
        #expect(!ParseResultValidator.isAcceptable(forty))
        #expect(ParseResultValidator.isAcceptable(fortyOne))
        #expect(ParserOutcome.minimumJSONURLCount == 41)
    }

    @Test("响应 header：只认 ua/User-Agent/Referer/Cookie（大小写不敏感），取不到才回落")
    func headers() throws {
        let body = try json(#"{"url":"https://cdn.example.com/a.m3u8","UA":"UA-1","referer":"https://site/","Cookie":"c=1","foo":"bar"}"#)
        let picked = ParseResultValidator.headers(fromJSON: body, fallback: ["User-Agent": "fallback"])
        #expect(picked["User-Agent"] == "UA-1")
        #expect(picked["Referer"] == "https://site/")
        #expect(picked["Cookie"] == "c=1")
        #expect(picked["foo"] == nil)

        let unrelated = try json(#"{"url":"https://cdn.example.com/a.m3u8","foo":"bar"}"#)
        let fallback = ParseResultValidator.headers(fromJSON: unrelated, fallback: ["User-Agent": "fallback"])
        #expect(fallback["User-Agent"] == "fallback")

        let nullValue = try json(#"{"UA":null,"foo":"bar"}"#)
        let nullFallback = ParseResultValidator.headers(fromJSON: nullValue, fallback: ["Referer": "fallback"])
        #expect(nullFallback["Referer"] == "fallback")
    }

    @Test("继续解析判定：parse=1 或 jx=1")
    func needsFollowUp() {
        var result = SpiderResult()
        #expect(!ParseResultValidator.needsFollowUp(result))

        result.parse = 1
        #expect(ParseResultValidator.needsFollowUp(result))

        var jedx = SpiderResult()
        jedx.jx = 1
        #expect(ParseResultValidator.needsFollowUp(jedx))
    }
}
