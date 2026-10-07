import CatVodCore
import Foundation
import Testing

@Suite("播放列表解析")
struct PlaylistParserTests {
    @Test("线路名与选集解析")
    func basicParsing() {
        #expect(PlaylistParser.lineNames("主线$$$备用线") == ["主线", "备用线"])
        #expect(PlaylistParser.lineNames("") == [])

        let episodes = PlaylistParser.episodes("第1集$id-1#第2集$id-2")
        #expect(episodes.count == 2)
        #expect(episodes[0].name == "第1集")
        #expect(episodes[0].url == "id-1")
    }

    @Test("省略集名时整段视为地址")
    func episodeWithoutName() {
        let episodes = PlaylistParser.episodes("https://cdn.example.com/e1.m3u8")
        #expect(episodes.count == 1)
        #expect(episodes[0].name.isEmpty)
        #expect(episodes[0].url == "https://cdn.example.com/e1.m3u8")
        #expect(episodes[0].displayName == "https://cdn.example.com/e1.m3u8")
    }

    @Test("地址为空的选集被丢弃")
    func dropEmptyEpisode() {
        let episodes = PlaylistParser.episodes("第1集$#第2集$id-2#")
        #expect(episodes.count == 1)
        #expect(episodes[0].url == "id-2")
    }

    @Test("线路数量不足时补占位线路名，不丢数据")
    func mismatchedCounts() {
        let lines = PlaylistParser.parse(playFrom: "主线", playURL: "a$$$b$$$c")
        #expect(lines.count == 3)
        #expect(lines.map(\.name) == ["主线", "线路 2", "线路 3"])
        #expect(lines[2].episodes.first?.url == "c")

        let reversed = PlaylistParser.parse(playFrom: "A$$$B$$$C", playURL: "x")
        #expect(reversed.count == 3)
        #expect(reversed[1].episodes.isEmpty)
    }

    @Test("空播放列表返回空数组")
    func emptyPlaylist() {
        #expect(PlaylistParser.parse(playFrom: "", playURL: "").isEmpty)
    }

    @Test("一致性校验输出可记录告警")
    func consistency() {
        let issues = PlaylistParser.consistencyIssues(playFrom: "主线$$$", playURL: "a$$$b")
        #expect(issues.contains { $0.contains("线路名为空") })

        let mismatch = PlaylistParser.consistencyIssues(playFrom: "主线", playURL: "a$$$b")
        #expect(mismatch.contains { $0.contains("不一致") })

        let noEpisode = PlaylistParser.consistencyIssues(playFrom: "主线", playURL: "")
        #expect(noEpisode.contains { $0.contains("没有可用选集") })

        #expect(PlaylistParser.consistencyIssues(playFrom: "主线", playURL: "第1集$id").isEmpty)
    }
}

@Suite("playUrl 前缀路由")
struct PlayUrlPrefixTests {
    @Test("前缀识别")
    func routing() {
        #expect(PlayUrlPrefix.route("") == PlaybackInstruction.none)
        #expect(PlayUrlPrefix.route("json:https://a/parse?url=") == .json(url: "https://a/parse?url="))
        #expect(PlayUrlPrefix.route("parse:演示解析") == .parser(name: "演示解析"))
        #expect(PlayUrlPrefix.route("https://jx.example.com/?url=") == .web(url: "https://jx.example.com/?url="))
        // 空参数视为无指令
        #expect(PlayUrlPrefix.route("json:") == PlaybackInstruction.none)
        #expect(PlayUrlPrefix.route("parse:") == PlaybackInstruction.none)
    }

    @Test("结果级 playUrl 优先于站点级")
    func resolutionPriority() {
        #expect(
            PlayUrlPrefix.resolve(sitePlayUrl: "parse:站点解析", resultPlayUrl: "json:https://x/y?url=")
                == .json(url: "https://x/y?url=")
        )
        #expect(
            PlayUrlPrefix.resolve(sitePlayUrl: "parse:站点解析", resultPlayUrl: "")
                == .parser(name: "站点解析")
        )
        #expect(PlayUrlPrefix.resolve(sitePlayUrl: "", resultPlayUrl: "") == PlaybackInstruction.none)
    }

    @Test("取出解析器名称")
    func parserNameExtraction() {
        #expect(PlayUrlPrefix.parserName(in: .parser(name: "演示解析")) == "演示解析")
        #expect(PlayUrlPrefix.parserName(in: .none) == nil)
        #expect(PlayUrlPrefix.parserName(in: .web(url: "https://x")) == nil)
    }
}
