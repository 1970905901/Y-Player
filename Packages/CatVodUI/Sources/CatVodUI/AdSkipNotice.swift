import CatVodNet
import Foundation

/// 「已跳过广告」的提示文案（M06k）。
///
/// 抽成纯函数是为了能测：这句话会在播放页反复出现，错了（虚报、单位写错、0 段也弹）比不显示更烦人。
enum AdSkipNotice {
    /// 文案；没跳过任何东西时返回空串（界面据此不显示这一行）。
    static func text(for stats: AdSkipRecorder.Stats) -> String {
        guard stats.removedSegments > 0 else {
            return ""
        }
        let seconds = Int(stats.removedDurationSec.rounded())
        let duration = seconds > 0 ? "，约 \(seconds) 秒" : ""
        return "已跳过广告 \(stats.removedSegments) 段\(duration)"
    }
}
