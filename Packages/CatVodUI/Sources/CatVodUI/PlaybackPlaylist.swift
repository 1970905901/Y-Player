import CatVodCore
import CatVodPlayer
import CatVodStore

/// 播放页**自己换集**所需的一切（M12P1）。
///
/// 为什么要它：播放页是导航栈里最深的一页，「下一集」不该让用户退回去再点一次；
/// 而换集的方式与站点类型有关（直链同步给资源、js2p/type=4 要先去站点换地址、解析链那种给不了），
/// 所以由**宿主**（详情页）把「第 i 集怎么变成资源」包成一个闭包传进来 —— 播放页不认识站点。
struct PlaybackPlaylist {
    /// 集列表（「选集」抽屉画的就是它）。
    let episodes: [PlaylistParser.Episode]
    /// 进播放页时是第几集。
    let currentIndex: Int
    /// 把第 i 集变成可播资源；`nil` = 这条路播放页走不了（例如需要解析链的集，回详情页处理）。
    let loadResource: (Int) async -> PlaybackEpisodeResource?
    /// 换集回传口：宿主据此更新「上次看到 / 进度键里的集下标」等（可选）。
    let onIndexChanged: ((Int) -> Void)?

    init(
        episodes: [PlaylistParser.Episode],
        currentIndex: Int,
        loadResource: @escaping (Int) async -> PlaybackEpisodeResource?,
        onIndexChanged: ((Int) -> Void)? = nil
    ) {
        self.episodes = episodes
        self.currentIndex = currentIndex
        self.loadResource = loadResource
        self.onIndexChanged = onIndexChanged
    }

    /// 某一集的显示名（空名回落到「第 N 集」，与详情页同一套口径）。
    func episodeName(at index: Int) -> String {
        guard episodes.indices.contains(index) else {
            return ""
        }
        let name = episodes[index].name
        return name.isEmpty ? "第 \(index + 1) 集" : name
    }

    /// 下一集是谁（纯规则在 ``PlaybackPlaylistRules``）。
    func nextIndex(after index: Int?) -> Int? {
        PlaybackPlaylistRules.nextIndex(current: index, count: episodes.count)
    }
}

/// 换一集的结果：资源 + 它对应的进度上下文。
///
/// 进度上下文必须跟着换：进度键里的 `episodeIndex` 变了，续播位置与「上次看到」才指向新集。
/// 标题也要换（导航栏与「下载本集」都读它）。
struct PlaybackEpisodeResource {
    let resource: MediaResource
    let progressContext: PlaybackProgressContext?
    let title: String
}

/// 播放页换集的**纯规则**（有单测）。
enum PlaybackPlaylistRules {
    /// 下一集下标；没有（最后一集 / 只有一集 / 没有播放列表）返回 nil。
    static func nextIndex(current: Int?, count: Int) -> Int? {
        guard let current, current >= 0, current < count - 1 else {
            return nil
        }
        return current + 1
    }
}
