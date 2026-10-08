import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("直播源列表（M07d-2）")
struct LiveSourceListTests {
    private func makeSource(_ json: String) throws -> LiveSource {
        try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    private func makeLoaded(name: String, channels: Int) throws -> LiveSource {
        let channelsJSON = (0 ..< channels).map { "{\"name\":\"C\($0)\",\"urls\":[\"http://a/\($0).m3u8\"]}" }
        let json = "{\"name\":\"\(name)\",\"groups\":[{\"name\":\"央视\",\"channel\":[\(channelsJSON.joined(separator: ","))]}]}"
        return try makeSource(json)
    }

    @Test("类型文案：`0` 直读清单、`3` Spider，其它取值原样写出（不猜含义）")
    func typeNames() {
        #expect(LiveSourceList.typeName(0) == "清单（TXT / M3U / JSON）")
        #expect(LiveSourceList.typeName(3) == "Spider（JS）")
        #expect(LiveSourceList.typeName(7) == "type 7")
    }

    @Test("摘要：只有**当前已解析**的那个源才报频道数，其它源只报类型")
    func detailUsesLoadedSourceOnly() throws {
        let sources = [
            try makeSource("{\"name\":\"主源\",\"type\":0}"),
            try makeSource("{\"name\":\"备用源\",\"type\":3}"),
        ]
        let loaded = try makeLoaded(name: "主源", channels: 3)

        let rows = LiveSourceList.rows(sources, selected: "主源", loaded: loaded)
        #expect(rows.map(\.name) == ["主源", "备用源"])
        #expect(rows[0].detail == "清单（TXT / M3U / JSON） · 3 个频道")
        #expect(rows[1].detail == "Spider（JS）")
        #expect(rows.map(\.isSelected) == [true, false])

        // 选中的是另一个源、且还没解析：两边都只报类型（不编频道数）。
        let unloaded = LiveSourceList.rows(sources, selected: "备用源", loaded: nil)
        #expect(unloaded.map(\.detail) == ["清单（TXT / M3U / JSON）", "Spider（JS）"])
        #expect(unloaded.map(\.isSelected) == [false, true])
    }

    @Test("解析结果为空清单时不报「0 个频道」——那时摘要只留类型")
    func emptyLoadedFallsBackToType() throws {
        let source = try makeSource("{\"name\":\"主源\",\"type\":0}")
        let loaded = try makeSource("{\"name\":\"主源\"}")
        #expect(LiveSourceList.row(source, selected: "主源", loaded: loaded).detail == "清单（TXT / M3U / JSON）")
    }

    @Test("空配置：没有源就没有行（界面据此不显示这一组）")
    func emptySources() {
        #expect(LiveSourceList.rows([], selected: "", loaded: nil).isEmpty)
    }
}
