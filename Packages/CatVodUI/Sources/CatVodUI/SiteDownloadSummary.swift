import Foundation

/// 逐集换地址下载（M10i 下半场）的结果文案。
///
/// 单独拎出来是因为它**要如实报三样**：新排上多少、本来就在队列里多少、多少集换不到地址 ——
/// 只写「已排 N 集」会把失败盖住，而失败恰恰是用户要决定「那几集怎么办」的依据。
enum SiteDownloadSummary {
    /// 纯函数，单测覆盖。
    static func text(queued: Int, alreadyQueued: Int, failed: Int) -> String {
        var parts: [String] = []
        if queued > 0 {
            parts.append("已排 \(queued) 集")
        }
        if alreadyQueued > 0 {
            parts.append("\(alreadyQueued) 集本来就在队列里")
        }
        if failed > 0 {
            parts.append("\(failed) 集换不到地址")
        }
        guard !parts.isEmpty else {
            return "没有可下载的集。"
        }
        var text = parts.joined(separator: "，") + "。"
        if failed > 0 {
            // 给一条**可执行的**下一步，而不是只说失败
            text += "换不到的多半是要走解析链：先单独播一次那几集，再用播放页的「下载本集」。"
        }
        return text
    }
}
