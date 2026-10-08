@testable import CatVodUI
import Testing

/// 广告规则开关的存档：**状态键 → 开 / 关**。
///
/// 状态键里已经含源标识摘要（见 `HLSAdRuleState`），所以这里不用再按接口分桶 ——
/// 但要盯住一件事：**传 `nil` 是「清掉本地开关」而不是「记一个显式的关」**。
/// 少了这条，「恢复默认」会变成「永远关着」，而界面上看起来已经还原了。
@Suite("广告规则开关存档")
struct HLSAdRuleBookTests {
    @Test("编码 / 解码往返")
    func roundTrip() {
        let book = ["hlsRules:ab12cd34:rule-1": true, "hlsRules:ab12cd34:rule-2": false]

        #expect(HLSAdRuleBook.decode(HLSAdRuleBook.encode(book)) == book)
    }

    @Test("脏存档当空，绝不抛")
    func brokenDataFallsBack() {
        #expect(HLSAdRuleBook.decode(nil).isEmpty)
        #expect(HLSAdRuleBook.decode("").isEmpty)
        #expect(HLSAdRuleBook.decode("{").isEmpty)
        #expect(HLSAdRuleBook.decode(#"["a"]"#).isEmpty)
    }

    @Test("写入 / 清掉 / 空键不动存档")
    func recording() {
        let written = HLSAdRuleBook.recording(true, for: "k1", in: [:])
        #expect(written == ["k1": true])

        // nil = 回到规则自己的默认值（不是留一个显式的关）
        #expect(HLSAdRuleBook.recording(nil, for: "k1", in: written).isEmpty)
        #expect(HLSAdRuleBook.recording(false, for: "k1", in: written) == ["k1": false])
        #expect(HLSAdRuleBook.recording(true, for: "", in: written) == written)
    }
}
