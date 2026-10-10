import CatVodCore
import Foundation

/// 一次弹幕请求（播放页要搜什么）：片名 + 集名。
///
/// 为什么单独一个小类型：弹幕搜索要的是**两个字段**，而播放页的上层拿到的是各种拼好的标题
/// （`片名 · 第1集`）—— 传一个小结构比让 `DanmakuService` 去猜标题怎么切更实在。
public struct DanmakuRequest: Sendable, Equatable {
    public var name: String
    public var episode: String

    public init(name: String, episode: String) {
        self.name = name
        self.episode = episode
    }

    /// 两个都空 = 没什么可搜的（界面据此不触发请求）。
    public var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && episode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 弹幕在播放页显示的一行状态（M08c）。
///
/// 抽成小枚举 + 纯文案，理由与 ``AdSkipNotice`` 一样：这句话会反复出现，
/// 「加载中」和「没搜到」混了会让用户以为一直卡着；失败原因要能看出来才可查。
public enum DanmakuStatus: Equatable {
    /// 不显示（开关关着，或用户没填地址 —— 那是他的选择，不必提示）。
    case idle
    case loading
    /// 搜到了：来自哪个源、多少条。
    case loaded(source: String, count: Int)
    /// 接口通了但没有候选 —— 与「加载失败」是两件事。
    case empty
    /// 选中的那份弹幕**文件里没有行**（M03P25 从 `.empty` 里分出来）：下一步是「换一条」，
    /// 不是去改弹幕 API 地址 —— 两句提示不能共用。
    case emptySource(String)
    case failed(String)

    /// 播放页那一行的文案；空串 = 不显示这一行。
    public var text: String {
        switch self {
        case .idle:
            return ""
        case .loading:
            return "弹幕：加载中…"
        case let .loaded(source, count):
            let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "弹幕：\(count) 条" : "弹幕：\(name) · \(count) 条"
        case .empty:
            return "弹幕：没搜到（可在设置 → 播放 → 弹幕 API 换个地址）"
        case let .emptySource(source):
            let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "弹幕：这份文件里没有弹幕（换一条试试）" : "弹幕：\(name) 里没有弹幕（换一条试试）"
        case let .failed(reason):
            return "弹幕：加载失败 — \(reason)"
        }
    }

    /// 是否该在界面上显示这一行。
    public var isVisible: Bool {
        !text.isEmpty
    }
}
