import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

/// 多仓（`urls`）条目：绝对 / 相对地址的解析规则，以及「点不动」的那一类（M18P2）。
@Suite("多仓子配置条目")
struct ConfigSubURLsTests {
    @Test("绝对地址：原样给 URL；空白项丢掉")
    func absoluteEntries() {
        let entries = ConfigSubURLs.entries(
            ["https://a.example/1.json", "   ", "http://b.example/2.json"],
            relativeTo: nil
        )
        #expect(entries.map(\.raw) == ["https://a.example/1.json", "http://b.example/2.json"])
        #expect(entries.first?.url?.absoluteString == "https://a.example/1.json")
    }

    @Test("相对地址：按**当前配置地址**解析（配置里 `./sub.json` 这种写法很常见）")
    func relativeEntriesResolveAgainstOrigin() throws {
        let origin = try #require(URL(string: "https://cdn.example/warehouse/main.json"))
        let entries = ConfigSubURLs.entries(["./sub.json", "other.json"], relativeTo: origin)
        #expect(entries.first?.url?.absoluteString == "https://cdn.example/warehouse/sub.json")
        #expect(entries.last?.url?.absoluteString == "https://cdn.example/warehouse/other.json")
    }

    @Test("相对地址但没有基准（内联配置）：给 nil —— 界面置灰并写明原因，不做点了没反应")
    func relativeWithoutOriginIsNotClickable() {
        let entries = ConfigSubURLs.entries(["./sub.json"], relativeTo: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.raw == "./sub.json")
        #expect(entries.first?.url == nil)
    }
}
