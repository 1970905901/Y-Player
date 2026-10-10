import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

/// 「按源名存的显式布尔覆盖」的存档：`pass`（M07d-5）与 `boot`（M07d-9）共用这一份实现。
@Suite("直播源的布尔覆盖存档")
struct LiveSourceFlagBookTests {
    @Test("存档：按源名分桶、JSON 往返；坏存档当空")
    func roundTrip() {
        let book = LiveSourceFlagBook.setting(true, for: "演示直播", in: [:])
        #expect(book == ["演示直播": true])
        #expect(LiveSourceFlagBook.decode(LiveSourceFlagBook.encode(book)) == book)

        // 两个方向都要存得住（源里写了 `true`、用户关掉 → 存 false 而不是删掉）。
        let off = LiveSourceFlagBook.setting(false, for: "备用源", in: book)
        #expect(off["备用源"] == false)
        #expect(LiveSourceFlagBook.decode(LiveSourceFlagBook.encode(off)) == off)

        // 空源名不写。
        #expect(LiveSourceFlagBook.setting(true, for: "", in: [:]).isEmpty)

        // 坏存档 / 空存档 / 不是对象。
        #expect(LiveSourceFlagBook.decode(nil).isEmpty)
        #expect(LiveSourceFlagBook.decode("").isEmpty)
        #expect(LiveSourceFlagBook.decode("{不是 JSON").isEmpty)
        #expect(LiveSourceFlagBook.decode("[\"数组不是表\"]").isEmpty)
        #expect(LiveSourceFlagBook.decode("{\"\":true,\"演示直播\":false}") == ["演示直播": false])
    }

    @Test("清掉覆盖：回到「跟源自己的字段」；本来没有覆盖就原样返回")
    func clearing() {
        let book = LiveSourceFlagBook.setting(true, for: "演示直播", in: [:])
        #expect(LiveSourceFlagBook.clearing("演示直播", in: book).isEmpty)
        #expect(LiveSourceFlagBook.clearing("不存在的源", in: book) == book)
        #expect(LiveSourceFlagBook.clearing("", in: book) == book)
    }
}
