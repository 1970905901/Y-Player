import CatVodCore
import CatVodPlayer
import CatVodStore

/// 播放页**自己换集**所需的一切（M12P1）。
///
/// 为什么要它：播放页是导航栈里最深的一页，「下一集」不该让用户退回去再点一次；
/// 而换集的方式与站点类型有关（直链同步给资源、js2p/type=4 要先去站点换地址、解析链那种给不了），
/// 所以由**宿主**（详情页）把「第 i 集怎么变成资源」包成一个闭包传进来 —— 播放页不认识站点。
///
/// `public` 的理由很直接：`PlaybackView` 是 public，它的 init 收这个类型 ——
/// 参数类型不能比 init 更内敛（编译期就会报「initializer cannot be declared public…」）。
public struct PlaybackPlaylist {
    /// 集列表（「选集」抽屉画的就是它）。
    public let episodes: [PlaylistParser.Episode]
    /// 进播放页时是第几集。
    public let currentIndex: Int
    /// 把第 i 集变成可播资源；`nil` = 这条路播放页走不了（例如需要解析链的集，回详情页处理）。
    public let loadResource: (Int) async -> PlaybackEpisodeResource?
    /// 换集回传口：宿主据此更新「上次看到 / 进度键里的集下标」等（可选）。
    public let onIndexChanged: ((Int) -> Void)?

    public init(
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

    /// 某一集的显示名（空名回落到「第 N 集」，与详情页选集卡片同一套口径）。
    public func episodeName(at index: Int) -> String {
        guard episodes.indices.contains(index) else {
            return ""
        }
        let name = episodes[index].name
        return name.isEmpty ? "第 \(index + 1) 集" : name
    }

    /// 下一集是谁（纯规则在 ``PlaybackPlaylistRules``）。
    public func nextIndex(after index: Int?) -> Int? {
        PlaybackPlaylistRules.nextIndex(current: index, count: episodes.count)
    }

    /// 上一集是谁（M03P23：播放页「下滑上一集」要用）。
    public func previousIndex(before index: Int?) -> Int? {
        PlaybackPlaylistRules.previousIndex(current: index, count: episodes.count)
    }
}

/// 换一集的结果：资源 + 它对应的进度上下文 + 标题。
///
/// 三样都必须跟着换：进度键里的 `episodeIndex` 变了续播位置才指对新集；
/// 标题变了导航栏与「下载本集」才不写着上一集。
public struct PlaybackEpisodeResource {
    public let resource: MediaResource
    public let progressContext: PlaybackProgressContext?
    public let title: String

    public init(resource: MediaResource, progressContext: PlaybackProgressContext?, title: String) {
        self.resource = resource
        self.progressContext = progressContext
        self.title = title
    }
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

    /// 上一集下标；没有（第一集 / 只有一集 / 没有播放列表）返回 nil（M03P23）。
    static func previousIndex(current: Int?, count: Int) -> Int? {
        guard let current, current > 0, current < count else {
            return nil
        }
        return current - 1
    }
}
