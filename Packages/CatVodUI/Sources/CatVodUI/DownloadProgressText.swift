import Foundation

/// 下载列表里那两行进度文案（M25P2 收尾）：把「下到哪了」说准。
///
/// 口径与执行器一致（M10a / M25 / M25P2）：
/// - **总量只有真知道时才报**：直链的 `Content-Length` 一拿到手就知道整份多大，界面就说
///   「已下 1.2 GB / 3.4 GB」；HLS 中途不知道总量（要等所有片段收完才算得出来），只说
///   「已下 1.2 GB」—— 不拿收过的前缀冒充总量；
/// - HLS 运行中还报**片段数**（`n/m 片`）—— 中途唯一诚实的比例；片段数只在运行中拿得到
///   （`downloadRunSegmentTotals` 是过程态，跑完即清），暂停后只剩字节账目。
///
/// 抽成纯函数放这儿（不埋在 View 里）是为了能单测：文案是最容易「悄悄说错」的地方。
enum DownloadProgressText {
    /// 运行中那一行：有片段数就报片段（HLS），否则报字节。
    static func running(
        received: Int64,
        expected: Int64,
        completedSegments: Int,
        totalSegments: Int
    ) -> String {
        if totalSegments > 0 {
            return "已下 \(StorageSpace.format(received)) · \(completedSegments)/\(totalSegments) 片"
        }
        return byteText(received: received, expected: expected)
    }

    /// 暂停那一行（账目在暂停时并进任务里；M25 / M25P2）。
    static func paused(received: Int64, expected: Int64) -> String {
        byteText(received: received, expected: expected)
    }

    /// 字节那一半：总量**比下过的多**才写「X / Y」。
    ///
    /// 反过来（比如服务端给的 `Content-Length` 比实际还小）不写分母 —— 那会写出一个
    /// 「已下 3.4 GB / 3.3 GB」这种自相矛盾的行；到齐（相等）时也不写，那一刻它马上就完成了。
    private static func byteText(received: Int64, expected: Int64) -> String {
        let downloaded = StorageSpace.format(received)
        guard expected > received else {
            return "已下 \(downloaded)"
        }
        return "已下 \(downloaded) / \(StorageSpace.format(expected))"
    }
}
