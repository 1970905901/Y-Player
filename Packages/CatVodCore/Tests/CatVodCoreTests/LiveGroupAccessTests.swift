import CatVodCore
import Foundation
import Testing

@Suite("加密分组的可见性与解锁（M07d-4）")
struct LiveGroupAccessTests {
    private let groups = [
        LiveGroup(name: "央视", channels: [LiveChannel(name: "CCTV-1", urls: ["http://a/1.m3u8"])]),
        LiveGroup(name: "成人_1234"),
        LiveGroup(name: "备用_ab"),
    ]

    @Test("没解锁：隐藏分组不出现在可见列表里（上游把它们收在 `mHides`）")
    func hidesLockedGroups() {
        let visible = LiveGroupAccess.visible(groups, unlocked: [])
        #expect(visible.map(\.name) == ["央视"])

        let locked = LiveGroupAccess.locked(groups, unlocked: [])
        #expect(locked.map(\.name) == ["成人", "备用"])
        #expect(locked.map(\.pass) == ["1234", "ab"])
    }

    @Test("解锁一组后：那一组进可见列表，其余仍锁着")
    func revealsUnlockedGroup() {
        let key = LiveGroupAccess.key(groups[1])
        #expect(key == "成人_1234")
        let visible = LiveGroupAccess.visible(groups, unlocked: [key])
        #expect(visible.map(\.name) == ["央视", "成人"])
        #expect(LiveGroupAccess.locked(groups, unlocked: [key]).map(\.name) == ["备用"])
    }

    @Test("输密码解锁：严格相等、区分大小写；同一个密码能一次解开多组")
    func unlockingUsesExactMatch() {
        #expect(LiveGroupAccess.unlocking(groups, with: "1234").map(\.name) == ["成人"])
        #expect(LiveGroupAccess.unlocking(groups, with: "1235").isEmpty)
        // 空密码不解锁任何组（上游 `unlock(null)` 是生物识别那条路，这里不实现）。
        #expect(LiveGroupAccess.unlocking(groups, with: "").isEmpty)
        // 非隐藏分组永远不需要密码。
        #expect(LiveGroupAccess.unlocking(groups, with: "央视").isEmpty)

        let twin = [
            LiveGroup(name: "A_777"),
            LiveGroup(name: "B_777"),
            LiveGroup(name: "央视"),
        ]
        #expect(LiveGroupAccess.unlocking(twin, with: "777").map(\.name) == ["A", "B"])
    }

    @Test("非隐藏分组不受影响：有没有解锁集合都照常可见")
    func plainGroupsAlwaysVisible() {
        let key = LiveGroupAccess.key(groups[0])
        #expect(LiveGroupAccess.visible(groups, unlocked: [key]).map(\.name) == ["央视"])
        #expect(LiveGroupAccess.locked([groups[0]], unlocked: []).isEmpty)
    }
}
