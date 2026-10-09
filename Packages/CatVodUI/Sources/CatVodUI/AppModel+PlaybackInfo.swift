import CatVodCore
import Foundation

// 播放信息接线（M09d）：把结果体里那两个「解析进来了、界面没用」的字段接上。
//
// 起因是一次审计：`SpiderResult` 的 25 个字段里，`desc` 与 `jxFrom` **没有任何生产消费方**
// （`jxFrom` 连测试都只提了一次）。字段读进来了、界面没有，用户看到的就是「少了点东西」，
// 而且不会报错 —— 这类问题只能靠审计发现。
//
// 为什么这两个值得接（而不是像 `lrc` 那样标注「未做」）：
// - `jxFrom`（解析来源）是**排障信息**，用户在播放页能直接看到「这集是谁解的」；
// - `desc`（播放描述）是站点主动给的说明（换源提示、画质说明之类），白丢不合适。

public extension AppModel {
    /// 记下这次播放的来源与描述（拿到播放结果时调用）。
    func notePlaybackInfo(from result: SpiderResult) {
        parsedBy = result.jxFrom
        playbackDesc = result.desc
    }

    /// 清掉（换集 / 退出播放时）。
    func clearPlaybackInfo() {
        parsedBy = ""
        playbackDesc = ""
    }

    /// 播放页要显示的信息行（空的不进列表）。
    ///
    /// 放在模型里而不是视图里：这几句话会反复出现，文案与顺序值得测，
    /// 而视图层在这个项目里没有自动化测试。
    var playbackInfoRows: [String] {
        var rows: [String] = []
        if !parsedBy.isEmpty {
            rows.append("解析：\(parsedBy)")
        }
        if !playbackDesc.isEmpty {
            rows.append(playbackDesc)
        }
        return rows
    }
}
