import CatVodCore
import Testing

@Suite("播放页地址集合：对齐上游 CustomWebView.addUrl")
struct SniffedPageListTests {
    @Test("同一地址只返回一次 `true`（已在集合里就不再开窗口）")
    func dedupe() {
        var list = SniffedPageList()
        #expect(list.insert("https://a.example.com/player"))
        #expect(!list.insert("https://a.example.com/player"))
        #expect(list.urls == ["https://a.example.com/player"])
        #expect(!list.insert(""))
    }

    @Test("超过 MAX_URLS 先整体清空再插入（上游 `if (urls.size() > MAX_URLS) urls.clear()`）")
    func clearOverLimit() {
        var list = SniffedPageList()
        for index in 1 ... 8 {
            #expect(list.insert("https://a.example.com/\(index)"))
        }
        // 前 6 个把集合填到 6（此时 6 > 5）；第 7 个触发清空；第 8 个正常追加。
        #expect(list.urls == ["https://a.example.com/7", "https://a.example.com/8"])
    }

    @Test("上限与嗅探规则上限保持一致")
    func maximum() {
        #expect(SniffedPageList.maximum == SniffRules.maximumDetectedPages)
    }
}
