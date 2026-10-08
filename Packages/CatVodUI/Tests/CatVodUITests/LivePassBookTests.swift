import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("「组名里的 `_` 不当密码」覆盖的存档（M07d-5）")
struct LivePassBookTests {
    @Test("存档：按源名分桶、JSON 往返；坏存档当空")
    func roundTrip() {
        let book = LivePassBook.setting(true, for: "演示直播", in: [:])
        #expect(book == ["演示直播": true])
        #expect(LivePassBook.decode(LivePassBook.encode(book)) == book)

        // 两个方向都要存得住（源里写了 `pass: true`、用户关掉 → 存 false 而不是删掉）。
        let off = LivePassBook.setting(false, for: "备用源", in: book)
        #expect(off["备用源"] == false)
        #expect(LivePassBook.decode(LivePassBook.encode(off)) == off)

        // 空源名不写。
        #expect(LivePassBook.setting(true, for: "", in: [:]).isEmpty)

        // 坏存档 / 空存档 / 不是对象。
        #expect(LivePassBook.decode(nil).isEmpty)
        #expect(LivePassBook.decode("").isEmpty)
        #expect(LivePassBook.decode("{不是 JSON").isEmpty)
        #expect(LivePassBook.decode("[\"数组不是表\"]").isEmpty)
        #expect(LivePassBook.decode("{\"\":true,\"演示直播\":false}") == ["演示直播": false])
    }

    @Test("清掉覆盖：回到「跟源自己的 `pass`」；本来没有覆盖就原样返回")
    func clearing() {
        let book = LivePassBook.setting(true, for: "演示直播", in: [:])
        #expect(LivePassBook.clearing("演示直播", in: book).isEmpty)
        #expect(LivePassBook.clearing("不存在的源", in: book) == book)
        #expect(LivePassBook.clearing("", in: book) == book)
    }
}
