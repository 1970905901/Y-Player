@testable import CatVodUI
import Testing

/// 站点自定义名的存档：**接口摘要 → {站点 key: 名字}**（上游 `SiteNameStore` 的同款形状）。
///
/// 这一层最容易错的不是编码，而是**「恢复原名」的判定**：和原名一样的输入不能存成自定义名，
/// 否则用户再也没有「还原」这个动作可点（存档里存的是一个看起来一样的名字）。
@Suite("站点自定义名存档")
struct SiteNameBookTests {
    @Test("编码 / 解码往返")
    func roundTrip() {
        let book = ["cfg:abc": ["csp_x": "[主力]爸妈用"]]

        #expect(SiteNameBook.decode(SiteNameBook.encode(book)) == book)
    }

    @Test("脏存档当空，绝不抛")
    func brokenDataFallsBack() {
        #expect(SiteNameBook.decode(nil).isEmpty)
        #expect(SiteNameBook.decode("").isEmpty)
        #expect(SiteNameBook.decode("{").isEmpty)
        #expect(SiteNameBook.decode("[1,2,3]").isEmpty)
    }

    @Test("解码时清洗：空桶、空 key、空名字都丢掉")
    func decodeSanitizes() {
        let raw = """
        {"": {"a": "x"}, "cfg:abc": {"": "y", "b": "   ", "c": "  我的站  "}}
        """

        #expect(SiteNameBook.decode(raw) == ["cfg:abc": ["c": "  我的站  "]])
    }

    @Test("记一个名字：与原名一样就当成删除（用户才算真的还原）")
    func recordingTreatsOriginalNameAsRemoval() {
        let stored = SiteNameBook.recording("我的文件", rawName: "📁｜文件｜浏览", for: "a", config: "cfg:1", in: [:])
        #expect(stored == ["cfg:1": ["a": "我的文件"]])

        let reverted = SiteNameBook.recording("📁｜文件｜浏览", rawName: "📁｜文件｜浏览", for: "a", config: "cfg:1", in: stored)
        #expect(reverted.isEmpty)
    }

    @Test("清空名字也等于恢复原名；空桶要被删掉")
    func recordingClearsNameAndBucket() {
        let stored = SiteNameBook.recording("[主力]爸妈用", rawName: "XYQ线路一", for: "a", config: "cfg:1", in: [:])

        #expect(SiteNameBook.recording("   ", rawName: "XYQ线路一", for: "a", config: "cfg:1", in: stored).isEmpty)
        // 同一桶里还有别的站点时只删自己
        let two = SiteNameBook.recording("我爸用", rawName: "XYQ线路二", for: "b", config: "cfg:1", in: stored)
        let one = SiteNameBook.recording("", rawName: "XYQ线路一", for: "a", config: "cfg:1", in: two)
        #expect(one == ["cfg:1": ["b": "我爸用"]])
    }

    @Test("没有桶名或没有站点 key 就原样返回")
    func recordingWithoutBucketIsNoop() {
        let stored = ["cfg:1": ["a": "我的站"]]

        #expect(SiteNameBook.recording("x", rawName: "r", for: "a", config: "", in: stored) == stored)
        #expect(SiteNameBook.recording("x", rawName: "r", for: "", config: "cfg:1", in: stored) == stored)
    }
}
