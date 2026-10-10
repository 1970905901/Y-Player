import Foundation

/// 「要下这一集」的输入：集名 + 线路 + 地址。
///
/// 单独一个类型而不是直接收 ``DownloadTask``：调用方（详情页）手上只有选集信息，
/// 没有站点 / 片名 / 时间这些上下文 —— 那些由 ``DownloadQueue/tasksToAdd(_:existing:siteKey:title:headers:now:)`` 补。
public struct DownloadRequest: Sendable, Hashable {
    public var episode: String
    public var line: String
    public var url: String

    public init(episode: String, line: String = "", url: String) {
        self.episode = episode
        self.line = line
        self.url = url
    }
}

/// 下载队列的调度规则（M10a，纯逻辑）。
///
/// 与 ``DownloadTask`` 同一层：不做 IO、不发请求，只回答「现在该启动哪几条」「收到一段数据后
/// 状态怎么变」「失败之后回哪去」。执行层（URLSession / 分片下载）只负责照着做。
///
/// ⚠️ 上游没有参考实现，口径是本项目的设计（见 ``DownloadTask`` 的说明）。
public enum DownloadQueue {
    /// 同时下载的任务数上限。
    ///
    /// 为什么是 2 而不是「有多少跑多少」：手机上的瓶颈是带宽与发热，不是并发度 ——
    /// 同时开五条会把每条都拖慢，还让所有进度条一起卡住；2 条既吃得住带宽，
    /// 也让人看得清它在做什么。这个值是**规则**（有单测），不是随手写的常数。
    public static let concurrencyLimit = 2

    /// 此刻应该启动的任务（按创建时间，补到并发上限为止）。
    ///
    /// 只挑 `waiting`：`paused` 是用户的意愿，不能被这里「顺手」启动；
    /// `failed` 要用户点了重试才会回 `waiting`（见 ``retrying(_:)``）。
    public static func nextToStart(
        _ tasks: [DownloadTask],
        limit: Int = concurrencyLimit
    ) -> [DownloadTask] {
        let running = tasks.filter { $0.status == .running }.count
        let slots = max(0, limit - running)
        guard slots > 0 else {
            return []
        }
        return Array(
            tasks
                .filter { $0.status == .waiting }
                .sorted { $0.createdAt < $1.createdAt }
                .prefix(slots)
        )
    }

    /// 收到一段数据后的新任务：更新进度；到齐了就转 `finished`。
    ///
    /// 「到齐」的判定是 `expectedBytes > 0 && receivedBytes >= expectedBytes`。
    /// **没有总量**的任务（`expectedBytes == 0`）不会因为「收够了」自动完成 ——
    /// 那是传输层的事（流结束才算完），这里不猜。
    public static func applying(received: Int64, expected: Int64, to task: DownloadTask) -> DownloadTask {
        var copy = task
        copy.receivedBytes = max(0, received)
        if expected > 0 {
            copy.expectedBytes = expected
        }
        if copy.expectedBytes > 0, copy.receivedBytes >= copy.expectedBytes {
            return copy.transitioning(to: .finished)
        }
        return copy
    }

    /// 失败后的新任务：还在**自动重试**额度内就退回 `waiting` 并计数，否则停在 `failed`。
    ///
    /// 两种情况下都保留失败原因：重试时要能说清「上次为什么失败」，停下来时更要能说。
    public static func applying(failure reason: String, to task: DownloadTask) -> DownloadTask {
        var copy = task
        copy.retryCount += 1
        let next: DownloadTask.Status = copy.retryCount <= DownloadTask.retryLimit ? .waiting : .failed
        var updated = copy.transitioning(to: next)
        updated.failureReason = reason
        return updated
    }

    /// 用户手动重试 / 继续：回 `waiting` 并**重置自动重试额度**。
    ///
    /// 重置是有意的：手动按一次是明确的意图，不该因为之前把自动额度用完了就立刻再失败一次。
    public static func retrying(_ task: DownloadTask) -> DownloadTask {
        var copy = task
        copy.retryCount = 0
        return copy.transitioning(to: .waiting)
    }

    /// 用户暂停（也用于「正在下的那条被取消」的回执，M10m）：暂停不是失败 ——
    /// 不动重试额度，恢复走 ``retrying(_:)``。
    public static func pausing(_ task: DownloadTask) -> DownloadTask {
        task.transitioning(to: .paused)
    }

    /// 「整部下载」要新增哪些任务：跳过重复项（按 ``DownloadTask/id``），保持传入顺序（即剧集顺序）。
    ///
    /// 两处刻意的处理：
    /// - **没有地址的集不建任务** —— 建了也只会立刻失败，凭空给用户添一条错误；
    /// - 创建时间**逐个错开 1 毫秒**：队列按 `createdAt` 取「下一个」，
    ///   一批任务如果都带同一个时间戳，排序结果是不确定的（Swift 的 `sorted` 不稳定），
    ///   同一部剧下几集的顺序就会飘。
    public static func tasksToAdd(
        _ requests: [DownloadRequest],
        existing: [DownloadTask],
        siteKey: String,
        title: String,
        headers: [String: String] = [:],
        now: Date = Date()
    ) -> [DownloadTask] {
        var seen = Set(existing.map(\.id))
        var added: [DownloadTask] = []
        for (offset, request) in requests.enumerated() {
            guard !request.url.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            let task = DownloadTask(
                siteKey: siteKey,
                title: title,
                episode: request.episode,
                line: request.line,
                url: request.url,
                headers: headers,
                createdAt: now.addingTimeInterval(Double(offset) * 0.001)
            )
            guard !seen.contains(task.id) else {
                continue
            }
            seen.insert(task.id)
            added.append(task)
        }
        return added
    }
}
