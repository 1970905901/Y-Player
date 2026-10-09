@testable import CatVodSource
import Foundation
import Testing

/// 手动匹配表（M11 片 5）：token 形态、落盘往返、坏行处理。
struct TMDBMatchBookTests {
    @Test("token 往返：movie/tv 两种都认")
    func tokenRoundTrip() {
        let movie = TMDBMatchKey(kind: .movie, id: 603)
        #expect(movie.storageToken == "movie:603")
        #expect(TMDBMatchKey(storageToken: movie.storageToken) == movie)

        let tv = TMDBMatchKey(kind: .tv, id: 12345)
        #expect(tv.storageToken == "tv:12345")
        #expect(TMDBMatchKey(storageToken: tv.storageToken) == tv)
    }

    @Test("坏 token 一律给 nil（不认识就回落自动匹配，不拿错 id 去请求）")
    func badTokensGiveNil() {
        #expect(TMDBMatchKey(storageToken: "") == nil)
        #expect(TMDBMatchKey(storageToken: "movie") == nil)
        #expect(TMDBMatchKey(storageToken: "movie:") == nil)
        #expect(TMDBMatchKey(storageToken: "movie:abc") == nil)
        #expect(TMDBMatchKey(storageToken: "movie:0") == nil)
        #expect(TMDBMatchKey(storageToken: "movie:-1") == nil)
        #expect(TMDBMatchKey(storageToken: "book:1") == nil)
        #expect(TMDBMatchKey(storageToken: "movie:1:2") == nil)
        // 大小写不认：rawValue 就是小写，别默默放行
        #expect(TMDBMatchKey(storageToken: "Movie:1") == nil)
    }

    @Test("落盘往返：片名里的竖线 / 换行 / 空格都不撕坏格式")
    func storageRoundTripSurvivesHostileTitles() {
        let hostile = "仙逆|4K\n第二行"
        var book = TMDBMatchBook()
        book.setKey(TMDBMatchKey(kind: .tv, id: 99), for: hostile)
        book.setKey(TMDBMatchKey(kind: .movie, id: 7), for: "让子弹飞")

        // 落盘串里不含未编码的竖线：竖线只能是分隔符（每行恰好 1 个）
        for line in book.storageString.split(separator: "\n") {
            #expect(line.split(separator: "|", omittingEmptySubsequences: false).count == 2)
        }

        let restored = TMDBMatchBook(storageString: book.storageString)
        #expect(restored == book)
        #expect(restored.key(for: hostile) == TMDBMatchKey(kind: .tv, id: 99))
        #expect(restored.key(for: "让子弹飞") == TMDBMatchKey(kind: .movie, id: 7))
    }

    @Test("坏行只丢自己：好行照留")
    func malformedLinesAreDroppedIndividually() {
        let storage = [
            "仙逆|tv:1",
            "no-separator",
            "|movie:2",
            "空白|movie:0",
            "|",
            "杂物|book:3",
            "让子弹飞|movie:4",
        ].joined(separator: "\n")

        let book = TMDBMatchBook(storageString: storage)
        #expect(book.count == 2)
        #expect(book.key(for: "仙逆") == TMDBMatchKey(kind: .tv, id: 1))
        #expect(book.key(for: "让子弹飞") == TMDBMatchKey(kind: .movie, id: 4))
    }

    @Test("设 / 清一条：nil 是恢复自动匹配，空白片名忽略")
    func setAndClear() {
        var book = TMDBMatchBook()
        book.setKey(TMDBMatchKey(kind: .tv, id: 1), for: "仙逆")
        #expect(book.key(for: "仙逆") != nil)

        book.setKey(nil, for: "仙逆")
        #expect(book.key(for: "仙逆") == nil)
        #expect(book.isEmpty)

        book.setKey(TMDBMatchKey(kind: .tv, id: 1), for: "   ")
        #expect(book.isEmpty)
    }

    @Test("片名前后空格归一：写进去与查出来用同一把键")
    func titlesAreTrimmed() {
        let book = TMDBMatchBook(entries: ["仙逆": TMDBMatchKey(kind: .tv, id: 5)])
        #expect(book.key(for: " 仙逆 ") == TMDBMatchKey(kind: .tv, id: 5))

        var written = TMDBMatchBook()
        written.setKey(TMDBMatchKey(kind: .tv, id: 5), for: " 仙逆 ")
        #expect(written.titles == ["仙逆"])
        #expect(written.storageString == book.storageString)
    }

    @Test("落盘串稳定：同一张表两次写出同一串（按键排序）")
    func storageIsStable() {
        var book = TMDBMatchBook()
        book.setKey(TMDBMatchKey(kind: .movie, id: 2), for: "b片")
        book.setKey(TMDBMatchKey(kind: .movie, id: 1), for: "a片")
        book.setKey(TMDBMatchKey(kind: .movie, id: 3), for: "c片")

        let first = book.storageString
        #expect(first == book.storageString)
        #expect(TMDBMatchBook(storageString: first).storageString == first)
        #expect(book.titles == ["a片", "b片", "c片"])
    }

    @Test("空表：落盘是空串，还原也是空表")
    func emptyBook() {
        let empty = TMDBMatchBook()
        #expect(empty.isEmpty)
        #expect(empty.storageString.isEmpty)
        #expect(TMDBMatchBook(storageString: "").isEmpty)
        #expect(TMDBMatchBook(storageString: "\n\n").isEmpty)
    }

    @Test("displayText：两种类型各自说清")
    func displayText() {
        #expect(TMDBMatchKey(kind: .movie, id: 12).displayText == "电影 · 12")
        #expect(TMDBMatchKey(kind: .tv, id: 12).displayText == "剧集 · 12")
    }
}
