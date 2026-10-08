@testable import CatVodUI
import Testing

/// 分组顺序的存档：**接口地址 → 分组名数组**。
///
/// 存档坏了最坏就是回到默认顺序，但「回到默认」这个降级必须写死 —— 否则一份脏 JSON 会让
/// 站点面板打不开（这类 bug 在上游修过好几轮）。
@Suite("站点分组顺序存档")
struct SiteGroupOrderBookTests {
    @Test("编码 / 解码往返")
    func roundTrip() {
        let book = ["https://a.example.com/config": ["4K", "首页"]]

        #expect(SiteGroupOrderBook.decode(SiteGroupOrderBook.encode(book)) == book)
    }

    @Test("脏存档当空，绝不抛")
    func brokenDataFallsBack() {
        #expect(SiteGroupOrderBook.decode(nil).isEmpty)
        #expect(SiteGroupOrderBook.decode("").isEmpty)
        #expect(SiteGroupOrderBook.decode("{").isEmpty)
        #expect(SiteGroupOrderBook.decode("[1,2,3]").isEmpty)
        #expect(SiteGroupOrderBook.decode(#"{"a":["x"]}"#) == ["a": ["x"]])
    }

    @Test("解码时顺手清洗：空桶丢掉、顺序里的空项与重复项清掉")
    func decodeSanitizes() {
        let raw = #"{"a":["影视","","影视","  "],"":["4K"]}"#

        #expect(SiteGroupOrderBook.decode(raw) == ["a": ["影视"]])
    }

    @Test("写入某个接口的顺序；空顺序 = 删掉这一项；没有桶名就原样返回")
    func recording() {
        let written = SiteGroupOrderBook.recording(["4K", "首页"], for: "u1", in: [:])
        #expect(written == ["u1": ["4K", "首页"]])

        #expect(SiteGroupOrderBook.recording([], for: "u1", in: written).isEmpty)
        #expect(SiteGroupOrderBook.recording(["x"], for: "", in: written) == written)
        // 只动自己那一桶
        let two = SiteGroupOrderBook.recording(["首页"], for: "u2", in: written)
        #expect(two["u1"] == ["4K", "首页"])
        #expect(two["u2"] == ["首页"])
    }
}
