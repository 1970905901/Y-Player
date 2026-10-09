@testable import CatVodCore
import Testing

@Suite("下载队列：并发 / 进度推进 / 失败重试 / 批量加任务")
struct DownloadQueueTests {
    /// 固定时间基准：队列按 `createdAt` 排先后，测试不能靠 `Date()` 碰运气。
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func task(
        _ episode: String,
        status: DownloadTask.Status = .waiting,
        offset: Double = 0
    ) -> DownloadTask {
        DownloadTask(
            siteKey: "wogg",
            title: "某剧",
            episode: episode,
            line: "线路一",
            url: "https://cdn.example/\(episode).m3u8",
            status: status,
            createdAt: base.addingTimeInterval(offset)
        )
    }

    // MARK: - 并发

    @Test("补位：等待 3 条、并发上限 2 → 取最早的 2 条")
    func startsUpToLimit() {
        let tasks = [task("第 1 集", offset: 0), task("第 2 集", offset: 1), task("第 3 集", offset: 2)]
        let starting = DownloadQueue.nextToStart(tasks)
        #expect(starting.map(\.episode) == ["第 1 集", "第 2 集"])
    }

    @Test("补位：已经在下载 1 条 → 只补 1 条")
    func fillsRemainingSlots() {
        let tasks = [
            task("第 1 集", status: .running, offset: 0),
            task("第 2 集", offset: 1),
            task("第 3 集", offset: 2),
        ]
        #expect(DownloadQueue.nextToStart(tasks).map(\.episode) == ["第 2 集"])
    }

    @Test("补位：暂停 / 失败 / 已完成的都不会被自动启动")
    func neverAutoStartsOthers() {
        let tasks = [
            task("已暂停", status: .paused, offset: 0),
            task("已失败", status: .failed, offset: 1),
            task("已完成", status: .finished, offset: 2),
        ]
        #expect(DownloadQueue.nextToStart(tasks).isEmpty)
    }

    @Test("补位：并发已满就不启动（上限是规则，不是建议）")
    func respectLimit() {
        let tasks = [
            task("第 1 集", status: .running, offset: 0),
            task("第 2 集", status: .running, offset: 1),
            task("第 3 集", offset: 2),
        ]
        #expect(DownloadQueue.nextToStart(tasks).isEmpty)
    }

    // MARK: - 进度推进

    @Test("收到数据：更新进度，到齐转已完成")
    func advancingProgress() {
        let running = task("第 1 集", status: .running)
        let partial = DownloadQueue.applying(received: 300, expected: 1000, to: running)
        #expect(partial.receivedBytes == 300)
        #expect(partial.status == .running)
        #expect(partial.progress == 0.3)

        let done = DownloadQueue.applying(received: 1000, expected: 1000, to: partial)
        #expect(done.status == .finished)
        #expect(done.isFinished)
    }

    @Test("没有总量时不会「收够了」就完成：那是传输层的事，这里不猜")
    func unknownSizeNeverAutoFinishes() {
        let done = DownloadQueue.applying(received: 999_999, expected: 0, to: task("第 1 集", status: .running))
        #expect(done.status == .running)
        #expect(done.progress == nil)
    }

    // MARK: - 失败与重试

    @Test("失败：额度内退回排队并计数，用完停在失败")
    func retriesUntilBudget() {
        var item = task("第 1 集", status: .running)
        for attempt in 1 ... DownloadTask.retryLimit {
            item = DownloadQueue.applying(failure: "第 \(attempt) 次挂了", to: item)
            #expect(item.status == .waiting)
            #expect(item.retryCount == attempt)
            item = item.transitioning(to: .running)
        }

        let stopped = DownloadQueue.applying(failure: "还是不行", to: item)
        #expect(stopped.status == .failed)
        #expect(stopped.failureReason == "还是不行")
        #expect(stopped.canAutoRetry == false)
    }

    @Test("重试中也会留着失败原因：界面上要能说清「上次为什么失败」")
    func keepsReasonWhileRetrying() {
        let retried = DownloadQueue.applying(failure: "连接超时", to: task("第 1 集", status: .running))
        #expect(retried.status == .waiting)
        #expect(retried.failureReason == "连接超时")
    }

    @Test("手动重试：回排队并重置自动额度（用户明确按了，不该立刻再失败）")
    func manualRetryResetsBudget() {
        var failed = task("第 1 集", status: .failed)
        failed.retryCount = DownloadTask.retryLimit
        let retried = DownloadQueue.retrying(failed)
        #expect(retried.status == .waiting)
        #expect(retried.retryCount == 0)
        #expect(retried.failureReason.isEmpty)
    }

    @Test("暂停：下载中 → 已暂停；已完成的按不动")
    func pausing() {
        #expect(DownloadQueue.pausing(task("第 1 集", status: .running)).status == .paused)
        #expect(DownloadQueue.pausing(task("第 1 集", status: .finished)).status == .finished)
    }

    // MARK: - 批量加任务

    @Test("批量加：跳过没有地址的集，保持剧集顺序，已存在的按标识去重")
    func tasksToAddSkipsDuplicatesAndEmpty() {
        let existing = [task("第 1 集")]
        let requests = [
            DownloadRequest(episode: "第 1 集", line: "线路一", url: "https://cdn.example/1.m3u8"),
            DownloadRequest(episode: "第 2 集", line: "线路一", url: ""),
            DownloadRequest(episode: "第 3 集", line: "线路一", url: "https://cdn.example/3.m3u8"),
            DownloadRequest(episode: "第 4 集", line: "线路一", url: "https://cdn.example/4.m3u8"),
        ]
        let added = DownloadQueue.tasksToAdd(
            requests,
            existing: existing,
            siteKey: "wogg",
            title: "某剧",
            now: base
        )
        #expect(added.map(\.episode) == ["第 3 集", "第 4 集"])
        // 闭包先挪到 `#expect` 外面：宏里带闭包容易展开失败，绑成 Bool 再断言。
        let allWaiting = added.allSatisfy { $0.status == .waiting }
        #expect(allWaiting)
    }

    @Test("批量加：同一批的时间逐个错开，队列顺序才稳定")
    func tasksToAddSpacesTimestamps() {
        let requests = (1 ... 3).map {
            DownloadRequest(episode: "第 \($0) 集", line: "线路一", url: "https://cdn.example/\($0).m3u8")
        }
        let added = DownloadQueue.tasksToAdd(requests, existing: [], siteKey: "wogg", title: "某剧", now: base)
        #expect(added.map(\.createdAt) == added.map(\.createdAt).sorted())
        #expect(Set(added.map(\.createdAt)).count == 3)
        // 队列按它取「下一个」，顺序必须是剧集顺序
        #expect(DownloadQueue.nextToStart(added).map(\.episode) == ["第 1 集", "第 2 集"])
    }
}
