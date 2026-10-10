import CatVodCore
@testable import CatVodUI
import Testing

@Suite("播放页换集：下一集是谁")
struct PlaybackPlaylistRulesTests {
    @Test("中间集有下一集；最后一集没有")
    func nextIndexBasics() {
        #expect(PlaybackPlaylistRules.nextIndex(current: 0, count: 3) == 1)
        #expect(PlaybackPlaylistRules.nextIndex(current: 1, count: 3) == 2)
        #expect(PlaybackPlaylistRules.nextIndex(current: 2, count: 3) == nil)
    }

    @Test("只有一集 / 空列表 / 没进过播放页：都没有下一集")
    func nextIndexEdges() {
        #expect(PlaybackPlaylistRules.nextIndex(current: 0, count: 1) == nil)
        #expect(PlaybackPlaylistRules.nextIndex(current: 0, count: 0) == nil)
        #expect(PlaybackPlaylistRules.nextIndex(current: nil, count: 5) == nil)
        // 下标越界（配置换过 / 进度里的集对不上）也不猜一个出来。
        #expect(PlaybackPlaylistRules.nextIndex(current: 9, count: 3) == nil)
        #expect(PlaybackPlaylistRules.nextIndex(current: -1, count: 3) == nil)
    }

    @Test("中间集有上一集；第一集没有")
    func previousIndexBasics() {
        #expect(PlaybackPlaylistRules.previousIndex(current: 2, count: 3) == 1)
        #expect(PlaybackPlaylistRules.previousIndex(current: 1, count: 3) == 0)
        #expect(PlaybackPlaylistRules.previousIndex(current: 0, count: 3) == nil)
    }

    @Test("只有一集 / 空列表 / 没进过播放页：都没有上一集")
    func previousIndexEdges() {
        #expect(PlaybackPlaylistRules.previousIndex(current: 0, count: 1) == nil)
        #expect(PlaybackPlaylistRules.previousIndex(current: 0, count: 0) == nil)
        #expect(PlaybackPlaylistRules.previousIndex(current: nil, count: 5) == nil)
        // 下标越界（配置换过 / 进度里的集对不上）也不猜一个出来。
        #expect(PlaybackPlaylistRules.previousIndex(current: 9, count: 3) == nil)
        #expect(PlaybackPlaylistRules.previousIndex(current: -1, count: 3) == nil)
    }

    @Test("播放列表：集名空时回落「第 N 集」，上一集 / 下一集都按列表算")
    func playlistHelpers() {
        let episodes = [
            PlaylistParser.Episode(name: "", url: "a"),
            PlaylistParser.Episode(name: "第 2 话", url: "b"),
        ]
        let playlist = PlaybackPlaylist(episodes: episodes, currentIndex: 0) { _ in nil }
        #expect(playlist.episodeName(at: 0) == "第 1 集")
        #expect(playlist.episodeName(at: 1) == "第 2 话")
        #expect(playlist.episodeName(at: 9).isEmpty)
        #expect(playlist.nextIndex(after: 0) == 1)
        #expect(playlist.nextIndex(after: 1) == nil)
        #expect(playlist.previousIndex(before: 1) == 0)
        #expect(playlist.previousIndex(before: 0) == nil)
    }
}
