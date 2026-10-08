import CatVodCore
import Foundation
import Testing

@Suite("「组名里的 `_` 不当密码」的本地覆盖（M07d-5）")
struct LiveSourcePassOverrideTests {
    private func makeSource(_ json: String) throws -> LiveSource {
        try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    @Test("`nil` 不覆盖：源里写什么就是什么")
    func nilKeepsSourceValue() throws {
        let plain = try makeSource(#"{"name":"演示直播"}"#)
        #expect(plain.applyingGroupPass(nil).pass == false)

        let configured = try makeSource(#"{"name":"演示直播","pass":true}"#)
        #expect(configured.applyingGroupPass(nil).pass)
    }

    @Test("覆盖两个方向都能拨：源里没写也能打开，源里写了也能关掉")
    func overrideBothWays() throws {
        // 源里没写（默认 false）→ 打开。
        let plain = try makeSource(#"{"name":"演示直播"}"#)
        #expect(plain.applyingGroupPass(true).pass)

        // 源里写了 true → 关掉（本地覆盖必须能盖过源自己的值，否则开关会「拨不动」）。
        let configured = try makeSource(#"{"name":"演示直播","pass":true}"#)
        #expect(configured.applyingGroupPass(false).pass == false)
    }

    @Test("覆盖不改别的字段（名字 / 地址 / header 原样）")
    func overrideKeepsOtherFields() throws {
        let source = try makeSource(#"{"name":"演示直播","url":"http://list/x.txt","ua":"UA"}"#)
        let applied = source.applyingGroupPass(true)
        #expect(applied.name == source.name)
        #expect(applied.url == source.url)
        #expect(applied.ua == source.ua)
        #expect(applied.groups.isEmpty)
    }
}
