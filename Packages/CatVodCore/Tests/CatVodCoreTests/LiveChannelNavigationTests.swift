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
}
