import CatVodCore
@testable import CatVodUI
import Testing

/// 播放页「选择弹幕」的候选拼法（M03P25）。
///
/// 为什么值得单测：候选列表是「站点自带 + 搜索到的」两批合起来的 ——
/// 顺序（自带的在前）与去重（同名字 + 同地址只留一条）都直接影响面板里第一眼看到什么。
@Suite("播放页选弹幕：候选的拼法")
struct PlaybackDanmakuSwitcherTests {
    @Test("站点自带的排前面；与搜索到的重复（同 id）只留一条；顺序稳定")
    func candidatesMerge() {
        let embedded = [
            DanmakuSource(name: "站点甲", url: "http://a/1.xml"),
            DanmakuSource(name: "站点乙", url: "http://b/2.xml"),
        ]
        let searched = [
            DanmakuSource(name: "站点乙", url: "http://b/2.xml"),
            DanmakuSource(name: "接口丙", url: "http://c/3.xml"),
        ]

        let merged = PlaybackDanmakuSwitcher.candidates(embedded: embedded, searched: searched)

        #expect(merged.map(\.name) == ["站点甲", "站点乙", "接口丙"])
    }

    @Test("两批都空：候选就是空的（面板据此不摆入口那一块）")
    func candidatesEmpty() {
        #expect(PlaybackDanmakuSwitcher.candidates(embedded: [], searched: []).isEmpty)
    }
}
