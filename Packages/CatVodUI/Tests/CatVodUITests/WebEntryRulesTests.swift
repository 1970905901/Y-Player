import CatVodCore
@testable import CatVodUI
import Testing

@Suite("网页条目：点开网页而不是详情页")
struct WebEntryRulesTests {
    private func site(api: String) -> Site {
        Site(key: "baseset", name: "配置|中心", type: 3, api: api)
    }

    @Test("config-center：用站点 api 的 scheme + host + port 拼 /website")
    func configCenterURL() {
        let url = WebEntryRules.webURL(
            for: VodItem(vodID: "config-center", vodName: "扫码配置"),
            site: site(api: "http://127.0.0.1:9988/spider/baseset/3")
        )
        #expect(url?.absoluteString == "http://127.0.0.1:9988/website")
    }

    @Test("vod_id 本身就是 http(s) 地址：直接用它")
    func directURL() {
        let url = WebEntryRules.webURL(for: VodItem(vodID: "https://example.com/config"), site: nil)
        #expect(url?.absoluteString == "https://example.com/config")
    }

    @Test("普通条目照旧（数字 id / 文字 id 不当网页）")
    func normalItemsStayNormal() {
        let baseset = site(api: "http://127.0.0.1:9988/spider/baseset/3")
        #expect(WebEntryRules.webURL(for: VodItem(vodID: "12345"), site: baseset) == nil)
        #expect(WebEntryRules.webURL(for: VodItem(vodID: "狂王"), site: baseset) == nil)
        // 没站点、或站点 api 里没有 host：不硬造地址，回落普通条目。
        #expect(WebEntryRules.webURL(for: VodItem(vodID: "config-center"), site: nil) == nil)
        #expect(WebEntryRules.webURL(for: VodItem(vodID: "config-center"), site: site(api: "baseset")) == nil)
    }
}
