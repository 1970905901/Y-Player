import CatVodCore
@testable import CatVodUI
import SwiftUI
import Testing

@Suite("搜索页：搜索历史与内嵌搜索栏")
struct SearchPageTests {
    // MARK: - SearchHistory

    @Test("记一次搜索：去空白、忽略空串、重复的提到最前")
    func addingKeyword() {
        #expect(SearchHistory.adding("狂王", to: []) == ["狂王"])
        #expect(SearchHistory.adding("  狂王  ", to: ["其它"]) == ["狂王", "其它"])
        #expect(SearchHistory.adding("", to: ["其它"]) == ["其它"])
        #expect(SearchHistory.adding("   ", to: ["其它"]) == ["其它"])
        // 已经在最前就不动（避免无意义的写盘）。
        #expect(SearchHistory.adding("狂王", to: ["狂王", "其它"]) == ["狂王", "其它"])
        // 在别的位置要提到最前，而不是留两条一样的。
        #expect(SearchHistory.adding("其它", to: ["狂王", "其它"]) == ["其它", "狂王"])
    }

    @Test("封顶：超出上限丢最旧的")
    func addingRespectsLimit() {
        var history: [String] = []
        let count = SearchHistory.limit + 5
        for index in 1 ... count {
            history = SearchHistory.adding("关键词\(index)", to: history)
        }
        #expect(history.count == SearchHistory.limit)
        #expect(history.first == "关键词\(count)")
        #expect(history.last == "关键词6")
    }

    @Test("存档往返：分隔符、换行与表情都不丢（所以用 JSON 而不是拼接分隔符）")
    func persistenceRoundTrip() {
        let history = ["狂王", "a|b", "换\n行", "😊emoji"]
        #expect(SearchHistory.decode(SearchHistory.encode(history)) == history)
        #expect(SearchHistory.decode("") == [])
        #expect(SearchHistory.decode("[]") == [])
        // 坏存档当空历史：历史坏了不该让搜索页打不开。
        #expect(SearchHistory.decode("这不是 JSON") == [])
        #expect(SearchHistory.decode("[1,2,3]") == [])
    }

    @Test("读存档也裁剪到上限（老存档里可能存过更多条）")
    func decodeTrimsToLimit() {
        let count = SearchHistory.limit + 3
        let tooMany = (1 ... count).map { "k\($0)" }
        #expect(SearchHistory.decode(SearchHistory.encode(tooMany)).count == SearchHistory.limit)
    }

    // MARK: - 展示件

    @Test("内嵌搜索栏能构造（iOS 走 .principal，macOS 走默认放置）")
    @MainActor
    func searchBarConstructs() {
        _ = Text("content").adaptiveSearchBar(
            text: .constant("狂王"),
            prompt: "请输入影片名称",
            trailing: { EmptyView() }
        )
    }
}
