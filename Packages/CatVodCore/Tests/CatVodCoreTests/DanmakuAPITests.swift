@testable import CatVodCore
import Testing

/// 弹幕搜索地址策略（对齐上游 `DanmakuApi`）。
///
/// 两种约定很容易写错：模板分支走 **GET**、基地址分支走 **POST**，而「要不要补 `/danmaku`」
/// 由路径段数决定 —— 补错一段，请求就打到一个不存在的接口上（现象是「弹幕一直加载失败」，
/// 但日志里看着地址挺正常）。
@Suite("弹幕搜索地址")
struct DanmakuAPITests {
    @Test("模板地址：替换 `{name}` / `{episode}`，走 GET")
    func templateUsesGet() throws {
        let request = try #require(
            DanmakuAPI.searchRequest(api: "https://d.example.com/api?n={name}&e={episode}", name: "片名", episode: "第1集")
        )
        guard case let .get(url) = request else {
            Issue.record("模板分支必须是 GET")
            return
        }
        #expect(url.absoluteString.contains("n=%E7%89%87%E5%90%8D"))
        #expect(url.absoluteString.contains("e=%E7%AC%AC1%E9%9B%86"))
    }

    @Test("基地址：补 `/danmaku` 并走 POST 表单")
    func baseURLUsesPost() throws {
        let request = try #require(DanmakuAPI.searchRequest(api: "https://d.example.com", name: "片名", episode: "1"))

        guard case let .post(url, fields) = request else {
            Issue.record("基地址分支必须是 POST")
            return
        }
        #expect(url.absoluteString == "https://d.example.com/danmaku")
        #expect(fields == ["name": "片名", "episode": "1"])
    }

    @Test("`getSearchUrl` 三条规则：已经是 danmaku / 路径超过一段 / 其余补一段")
    func searchURLRules() {
        #expect(DanmakuAPI.searchURL("https://d.example.com/danmaku")?.absoluteString == "https://d.example.com/danmaku")
        #expect(DanmakuAPI.searchURL("https://d.example.com/Danmaku")?.absoluteString == "https://d.example.com/Danmaku")
        #expect(DanmakuAPI.searchURL("https://d.example.com/api/v1")?.absoluteString == "https://d.example.com/api/v1")
        #expect(DanmakuAPI.searchURL("https://d.example.com/api")?.absoluteString == "https://d.example.com/api/danmaku")
        #expect(DanmakuAPI.searchURL("  ") == nil)
    }

    @Test("表单编码：空格用 `+`，键排序稳定")
    func formEncoding() {
        #expect(DanmakuAPI.formEncoded(["episode": "第 1 集", "name": "a b"]) == "episode=%E7%AC%AC+1+%E9%9B%86&name=a+b")
    }

    @Test("空地址不给请求（上游 `newCall` 返回 null）")
    func emptyAPIGivesNoRequest() {
        #expect(DanmakuAPI.searchRequest(api: "", name: "x", episode: "y") == nil)
    }
}
