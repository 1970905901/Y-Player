import CatVodCore
import Foundation
import Testing

@Suite("直播换台（M07d-3）")
struct LiveChannelNavigationTests {
    /// 四条频道：B 没有地址（不可播），其余三条可播。
    private func makeChannels() -> [LiveChannel] {
        [
            LiveChannel(name: "A", urls: ["http://a/1.m3u8"]),
            LiveChannel(name: "B"),
            LiveChannel(name: "C", urls: ["http://c/1.m3u8"]),
            LiveChannel(name: "D", urls: ["http://d/1.m3u8"]),
        ]
    }

    @Test("下一台 / 上一台：组内环形，跳过没有地址的频道")
    func wrapsAndSkipsUnplayable() {
        let channels = makeChannels()
        let a = channels[0]
        let c = channels[2]
        let d = channels[3]

        // A 往后：B 没地址被跳过 → C。
        #expect(LiveChannelNavigation.neighbor(of: a, step: 1, in: channels)?.name == "C")
        // C 往后 → D；D 往后（到末尾）→ 环形回到 A。
        #expect(LiveChannelNavigation.neighbor(of: c, step: 1, in: channels)?.name == "D")
        #expect(LiveChannelNavigation.neighbor(of: d, step: 1, in: channels)?.name == "A")
        // 往前：A 往前 → 环形到 D；D 往前 → C（跳过 B）。
        #expect(LiveChannelNavigation.neighbor(of: a, step: -1, in: channels)?.name == "D")
        #expect(LiveChannelNavigation.neighbor(of: d, step: -1, in: channels)?.name == "C")
    }

    @Test("跨过多个位置 / 超过一圈：按可播条数取模，仍然环形")
    func handlesBigSteps() {
        let channels = makeChannels()
        let a = channels[0]
        // 可播的有 3 条（A、C、D）：+2 从 A 出发 → D；+3 正好绕一圈 → A；
        // -4 从 A 往前数四步（A→D→C→A→D）→ D。
        #expect(LiveChannelNavigation.neighbor(of: a, step: 2, in: channels)?.name == "D")
        #expect(LiveChannelNavigation.neighbor(of: a, step: 3, in: channels)?.name == "A")
        #expect(LiveChannelNavigation.neighbor(of: a, step: -4, in: channels)?.name == "D")
    }

    @Test("纵甩换台的方向（M07d10）：默认上滑 = 上一台、下滑 = 下一台；invert 对调")
    func zapStepDirections() {
        // 上游 `LiveActivity.onFlingUp/Down` 的默认映射（与点播页的「上滑 = 下一集」相反）。
        #expect(LiveChannelNavigation.zapStep(swipeUp: true, invert: false) == -1)
        #expect(LiveChannelNavigation.zapStep(swipeUp: false, invert: false) == 1)
        // `LiveSetting.isInvert()` 打开：两件事对调。
        #expect(LiveChannelNavigation.zapStep(swipeUp: true, invert: true) == 1)
        #expect(LiveChannelNavigation.zapStep(swipeUp: false, invert: true) == -1)
        // 与 `neighbor` 接起来是「上滑往前、下滑往后」（默认）—— 方向不能反着进 `step`。
        let channels = makeChannels()
        let a = channels[0]
        let up = LiveChannelNavigation.zapStep(swipeUp: true, invert: false)
        let down = LiveChannelNavigation.zapStep(swipeUp: false, invert: false)
        #expect(LiveChannelNavigation.neighbor(of: a, step: up, in: channels)?.name == "D")
        #expect(LiveChannelNavigation.neighbor(of: a, step: down, in: channels)?.name == "C")
    }

    @Test("当前频道不在清单里（清单换过）：给第一个可播的")
    func unknownChannelFallsBackToFirstPlayable() {
        let channels = makeChannels()
        let stranger = LiveChannel(name: "已下架的频道", urls: ["http://x/1.m3u8"])
        #expect(LiveChannelNavigation.neighbor(of: stranger, step: 1, in: channels)?.name == "A")
        #expect(LiveChannelNavigation.neighbor(of: stranger, step: -1, in: channels)?.name == "A")

        // 不可播的那条也「不在可播清单里」→ 同样回落到第一个可播的（界面不会切到空地址）。
        #expect(LiveChannelNavigation.neighbor(of: channels[1], step: 1, in: channels)?.name == "A")
    }

    @Test("没有可换的：step 为 0 / 可播不足两个 → nil（界面据此置灰按钮）")
    func noNeighbor() {
        let channels = makeChannels()
        #expect(LiveChannelNavigation.neighbor(of: channels[0], step: 0, in: channels) == nil)
        #expect(LiveChannelNavigation.neighbor(of: channels[0], step: 1, in: []) == nil)

        let onlyOne = [LiveChannel(name: "A", urls: ["http://a/1.m3u8"])]
        #expect(LiveChannelNavigation.neighbor(of: onlyOne[0], step: 1, in: onlyOne) == nil)

        let nonePlayable = [LiveChannel(name: "A"), LiveChannel(name: "B")]
        #expect(LiveChannelNavigation.neighbor(of: nonePlayable[0], step: 1, in: nonePlayable) == nil)
    }

    // MARK: - 跨分组换台 / 按号码跳台（M07d-6）

    /// 三个分组：A（含一条没地址的）、空组、C。
    private func makeGroups() -> [LiveGroup] {
        [
            LiveGroup(name: "A", channels: [
                LiveChannel(name: "A1", urls: ["http://a/1.m3u8"]),
                LiveChannel(name: "A2", urls: ["http://a/2.m3u8"]),
            ]),
            LiveGroup(name: "空组", channels: [LiveChannel(name: "X")]),
            LiveGroup(name: "C", channels: [
                LiveChannel(name: "C1", urls: ["http://c/1.m3u8"]),
                LiveChannel(name: "C2", urls: ["http://c/2.m3u8"]),
            ]),
        ]
    }

    @Test("跨分组：往后去下一组的第一个可播、往前去上一组的最后一个（跳过整组不可播的分组）")
    func acrossGroups() {
        let groups = makeGroups()

        // A 往后 → 空组没有可播频道 → 跳过它 → C 的第一个。
        let forward = LiveChannelNavigation.across(in: groups[0], groups: groups, step: 1)
        #expect(forward?.group.name == "C")
        #expect(forward?.channel.name == "C1")

        // C 往前 → 空组同样跳过 → A 的**最后一个**（跨组是「跳到那组门口」）。
        let backward = LiveChannelNavigation.across(in: groups[2], groups: groups, step: -1)
        #expect(backward?.group.name == "A")
        #expect(backward?.channel.name == "A2")

        // 最后一组往后：循环回到第一组的第一个（不在边界失效）。
        let wrapped = LiveChannelNavigation.across(in: groups[2], groups: groups, step: 1)
        #expect(wrapped?.group.name == "A")
        #expect(wrapped?.channel.name == "A1")
    }

    @Test("跨分组：只有一个分组 / step 为 0 / 分组不在清单里 → nil")
    func acrossNeedsOtherGroups() {
        let groups = makeGroups()
        #expect(LiveChannelNavigation.across(in: groups[0], groups: [groups[0]], step: 1) == nil)
        #expect(LiveChannelNavigation.across(in: groups[0], groups: groups, step: 0) == nil)

        let stranger = LiveGroup(name: "已经不在清单里的组")
        #expect(LiveChannelNavigation.across(in: stranger, groups: groups, step: 1) == nil)

        // 一圈都没有可播频道：nil（界面据此置灰）。
        let dead = [
            LiveGroup(name: "A", channels: [LiveChannel(name: "A1")]),
            LiveGroup(name: "B", channels: [LiveChannel(name: "B1")]),
        ]
        #expect(LiveChannelNavigation.across(in: dead[0], groups: dead, step: 1) == nil)
    }

    @Test("按号码跳台：`001` 与 `1` 都认（整数比较），跨分组按顺序取第一个命中")
    func jumpByNumber() {
        var groups = makeGroups()
        groups[0].channels[0].number = "001"
        groups[2].channels[0].number = "001"

        let first = LiveChannelNavigation.channel(number: "1", in: groups)
        #expect(first?.group.name == "A")
        #expect(first?.channel.name == "A1")

        // 前导零 / 空白都能对上同一个频道。
        #expect(LiveChannelNavigation.channel(number: "  001  ", in: groups)?.channel.name == "A1")

        // 没有号的频道永远不命中（清单里补号之前是空串）。
        #expect(LiveChannelNavigation.channel(number: "2", in: groups) == nil)
        #expect(LiveChannelNavigation.channel(number: "002", in: groups) == nil)
    }

    @Test("按号码跳台：空串 / 非数字 / 找不到 → nil（上游 `Integer.parseInt` 会抛异常，这里不）")
    func jumpRejectsBadInput() {
        let groups = makeGroups()
        #expect(LiveChannelNavigation.channel(number: "", in: groups) == nil)
        #expect(LiveChannelNavigation.channel(number: "   ", in: groups) == nil)
        #expect(LiveChannelNavigation.channel(number: "CCTV-1", in: groups) == nil)
        #expect(LiveChannelNavigation.channel(number: "999", in: groups) == nil)
        #expect(LiveChannelNavigation.channel(number: "1", in: []) == nil)
    }
}
