import CatVodCore
import Foundation
import Testing

/// 直播「上次观看」（M07c-3）：上游 `Live.keep` 的字符串 `分组名@@@频道名@@@线路下标`。
@Suite("直播「上次观看」的编解码（M07c-3）")
struct LiveKeepTests {
    /// 一份够用的清单：央视组两条线路（第二条带线路名）+ 一条没有地址的频道，另有一个卫视频道。
    private func makeSource() throws -> LiveSource {
        let json = """
        {"name":"演示直播","groups":[
          {"name":"央视","channel":[
            {"name":"CCTV-1","urls":["http://a/1.m3u8$线路一","http://a/2.m3u8$线路二"]},
            {"name":"CCTV-2","urls":[]}
          ]},
          {"name":"卫视","channel":[{"name":"湖南卫视","urls":["http://b/1.m3u8"]}]}
        ]}
        """
        let data = Data(json.utf8)
        return try JSONDecoder().decode(LiveSource.self, from: data)
    }

    @Test("按上游形态解析：分组名@@@频道名@@@线路下标，且原样编回")
    func parsesUpstreamFormat() {
        let keep = LiveKeep(raw: "央视@@@CCTV-1@@@2")
        #expect(keep?.group == "央视")
        #expect(keep?.channel == "CCTV-1")
        #expect(keep?.line == 2)
        #expect(keep?.rawValue == "央视@@@CCTV-1@@@2")
    }

    @Test("宽容解析：多余的段忽略、线路下标缺失或坏掉按 0、空字段当没有记录")
    func toleratesMessyValues() {
        // 上游将来加字段：旧解析不该炸，按前两段 + 第三段走。
        #expect(LiveKeep(raw: "央视@@@CCTV-1@@@1@@@别的")?.line == 1)

        // 只有两段：线路下标按 0（上游 `Channel.getCurrent()` 默认也是 0）。
        #expect(LiveKeep(raw: "央视@@@CCTV-1")?.line == 0)

        // 第三段不是数字 / 是负数：同样按 0（构造会收敛）。
        #expect(LiveKeep(raw: "央视@@@CCTV-1@@@abc")?.line == 0)
        #expect(LiveKeep(raw: "央视@@@CCTV-1@@@-3")?.line == 0)

        // 缺分组名 / 缺频道名 / 空串 / 分隔符写错：一律当「没有上次观看」。
        #expect(LiveKeep(raw: "@@@CCTV-1@@@0") == nil)
        #expect(LiveKeep(raw: "央视@@@@@@0") == nil)
        #expect(LiveKeep(raw: "") == nil)
        #expect(LiveKeep(raw: "央视|CCTV-1|0") == nil)
    }

    @Test("解析到清单上：分组名 + 频道名命中，线路下标原样带出")
    func resolvesExactMatch() throws {
        let source = try makeSource()
        let target = LiveKeep(raw: "央视@@@CCTV-1@@@1")?.resolve(in: source)
        #expect(target?.group.name == "央视")
        #expect(target?.channel.name == "CCTV-1")
        #expect(target?.lineIndex == 1)
        #expect(target?.isPlayable == true)
    }

    @Test("解析到清单上：线路下标越界回落第 0 条；没有地址的频道不可播")
    func resolvesOutOfRangeLine() throws {
        let source = try makeSource()
        let far = LiveKeep(raw: "央视@@@CCTV-1@@@9")?.resolve(in: source)
        #expect(far?.lineIndex == 0)
        #expect(far?.isPlayable == true)

        let empty = LiveKeep(raw: "央视@@@CCTV-2@@@3")?.resolve(in: source)
        #expect(empty?.lineIndex == 0)
        #expect(empty?.isPlayable == false)
    }

    @Test("解析到清单上：分组名改过时按频道名找；频道没了就是 nil")
    func resolvesByChannelName() throws {
        let source = try makeSource()
        let renamed = LiveKeep(raw: "老分组名@@@湖南卫视@@@0")?.resolve(in: source)
        #expect(renamed?.group.name == "卫视")
        #expect(renamed?.channel.name == "湖南卫视")

        #expect(LiveKeep(raw: "央视@@@不存在的频道@@@0")?.resolve(in: source) == nil)
    }
}
