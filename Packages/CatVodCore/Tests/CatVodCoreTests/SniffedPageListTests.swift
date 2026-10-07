import CatVodCore
import Testing

@Suite("播放页地址集合：对齐上游 CustomWebView.addUrl")
struct SniffedPageListTests {
    @Test("同一地址只返回一次 `true`（已在集合里就不再开窗口）")
    func dedupe() {
        var list = SniffedPageList()
        // 注意：`#expect` 的参数会被宏包成闭包，里面**不能**调用 mutating 方法
        // （CI 报过 `cannot use mutating member on immutable value: '$0' is immutable`），
        // 所以先把结果取到局部变量再断言。
        let first = list.insert("https://a.example.com/player")
        let second = list.insert("https://a.example.com/player")
        let empty = list.insert("")
        #expect(first)
        #expect(!second)
        #expect(!empty)
        #expect(list.urls == ["https://a.example.com/player"])
    }

    @Test("超过 MAX_URLS 先整体清空再插入（上游 `if (urls.size() > MAX_URLS) urls.clear()`）")
    func clearOverLimit() {
        var list = SniffedPageList()
        var accepted = 0
        for index in 1 ... 8 where list.insert("https://a.example.com/\(index)") {
            accepted += 1
        }
        #expect(accepted == 8)
        // 前 6 个把集合填到 6（此时 6 > 5）；第 7 个触发清空；第 8 个正常追加。
        #expect(list.urls == ["https://a.example.com/7", "https://a.example.com/8"])
    }

    @Test("上限与嗅探规则上限一致；可用初始列表恢复状态")
    func maximum() {
        #expect(SniffedPageList.maximum == SniffRules.maximumDetectedPages)
        let restored = SniffedPageList(urls: ["https://a.example.com/player"])
        #expect(restored.urls.count == 1)
    }
}
