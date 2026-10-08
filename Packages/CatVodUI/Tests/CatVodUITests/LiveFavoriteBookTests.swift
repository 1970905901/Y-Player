import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("直播收藏的存档与分组条（M07c-5）")
struct LiveFavoriteBookTests {
    private func makeSource() throws -> LiveSource {
        let json = """
        {"name":"演示直播","groups":[
          {"name":"央视","channel":[{"name":"CCTV-1","urls":["http://a/1.m3u8"]}]},
          {"name":"卫视","channel":[{"name":"湖南卫视","urls":["http://b/1.m3u8"]}]}
        ]}
        """
        return try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    @Test("存档：按源名分桶、JSON 往返；坏存档当空、空条目丢掉")
    func roundTrip() {
        let favorite = LiveFavorite(
            name: "CCTV-1",
            logo: "http://a/1.png",
            group: "央视",
            createdAt: Date(timeIntervalSince1970: 1_799_978_400)
        )
        let book = LiveFavoriteBook.recording([favorite], for: "演示直播", in: [:])
        #expect(book["演示直播"] == [favorite])
        #expect(LiveFavoriteBook.decode(LiveFavoriteBook.encode(book)) == book)

        // 另一个源各记各的，互不覆盖。
        let two = LiveFavoriteBook.recording([LiveFavorite(name: "湖南卫视")], for: "备用源", in: book)
        #expect(two.count == 2)

        // 取消完所有收藏：那一桶写成空表，读回来时没有这个键（界面按「没有收藏」处理）。
        let cleared = LiveFavoriteBook.recording([], for: "演示直播", in: book)
        #expect(LiveFavoriteBook.decode(LiveFavoriteBook.encode(cleared))["演示直播"] == nil)

        // 坏存档 / 空源名 / 空频道名。
        #expect(LiveFavoriteBook.decode(nil).isEmpty)
        #expect(LiveFavoriteBook.decode("").isEmpty)
        #expect(LiveFavoriteBook.decode("{不是 JSON").isEmpty)
        #expect(LiveFavoriteBook.decode("[\"数组不是表\"]").isEmpty)
        #expect(LiveFavoriteBook.recording([favorite], for: "", in: [:]).isEmpty)
        #expect(LiveFavoriteBook.decode("{\"\":[{\"name\":\"CCTV-1\",\"logo\":\"\",\"group\":\"\",\"createdAt\":0}]}").isEmpty)
        #expect(LiveFavoriteBook.decode("{\"演示直播\":[{\"name\":\"\",\"logo\":\"\",\"group\":\"\",\"createdAt\":0}]}").isEmpty)
    }

    @Test("分组条：有收藏时「收藏」插在最前（带星标标记），没有就不给这一行")
    func favoriteGroupRow() throws {
        let source = try makeSource()

        let plain = LiveListLayout.groupRows(source)
        #expect(plain.map(\.name) == ["央视", "卫视"])
        #expect(plain.allSatisfy { !$0.isKeep })

        let rows = LiveListLayout.groupRows(source, favoriteCount: 2)
        #expect(rows.map(\.name) == ["收藏", "央视", "卫视"])
        #expect(rows[0].isKeep)
        #expect(rows[0].count == 2)
        #expect(!rows[0].isHidden)
    }
}
