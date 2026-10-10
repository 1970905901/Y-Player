@testable import CatVodUI
import Foundation
import Testing

/// 直播节目单缓存的接线（M07d7）：占用算得进「全部缓存」、也清得掉 ——
/// 缓存管理页那两行的**数据面**（页面上只是把这两个调用接到按钮上）。
@Suite("缓存管理：直播节目单缓存")
@MainActor
struct LiveEPGCacheWiringTests {
    @Test("节目单缓存进「全部缓存」的合计；清空后归零")
    func byteCountAndClear() throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // 直接往 model 的节目单缓存目录里写一份 —— 等价于「进过直播页、下过文件形态节目单」。
        let cache = model.liveEPGCache
        cache.store(Data(repeating: 0x41, count: 2048), for: "https://live.example.com/epg/cctv.xml")
        #expect(model.liveEPGCacheByteCount == 2048)
        #expect(model.totalCacheByteCount >= 2048)

        // 「清空全部」也把它清掉（三个清空按钮共用一次确认，数据面得一起动）。
        #expect(model.clearAllCaches() >= 1)
        #expect(model.liveEPGCacheByteCount == 0)
        #expect(cache.read("https://live.example.com/epg/cctv.xml") == nil)
    }
}
