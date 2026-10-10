import CatVodCore
import CatVodNet
import CatVodSource
import Foundation

// 离线下载的接线（M10e）：把 M10a（任务与队列规则）、M10b（落库）、M10d（执行器）串起来。
//
// 三处刻意的做法：
// - **库是唯一来源**：`downloadTasks` 只是镜像，任何写入都先落库再刷新（与收藏 / 播放进度同一套）
//   —— 否则会出现「界面上有、重启就没了」；
// - **失败不抛错**：下载失败只写进那一条任务的状态与原因，不带崩别的流程（与弹幕 / 字幕一致）；
// - **驱动只在前台跑，但不绑页面**：M10a 记的「后台下载」留口还没做，所以驱动是前台任务；
//   不过启动它的时机是「入队」与「回到前台」，不再要求用户停在「下载管理」页上
//   （以前只有那页的 `.task` 会驱动队列，在详情页点完「整部下载」转身去看剧 = 队列一动不动）。

public extension AppModel {
    /// 载入库里的下载任务。
    ///
    /// 读回来的 `running` 会被降级成 `waiting`（M10b 的恢复策略）—— 上次没跑完就被杀掉的
    /// 任务不能一直占着并发位。
    func synchronizeDownloads() async {
        downloadTasks = await Self.sortedDownloadTasks(downloadStore.all())
    }

    /// 入队一批（详情页的「下载本集 / 整部下载」）。
    ///
    /// 去重、跳过空地址、时间戳错开都在 ``DownloadQueue/tasksToAdd(_:existing:siteKey:title:headers:now:)``
    /// 里（那边有单测）；这里只负责落库与刷新。
    @discardableResult
    func enqueueDownloads(
        _ requests: [DownloadRequest],
        siteKey: String,
        title: String,
        headers: [String: String] = [:]
    ) async -> [DownloadTask] {
        let added = DownloadQueue.tasksToAdd(
            requests,
            existing: downloadTasks,
            siteKey: siteKey,
            title: title,
            headers: headers
        )
        guard !added.isEmpty else {
            return []
        }
        await downloadStore.save(added)
        await synchronizeDownloads()
        return added
    }

    /// 暂停。排队中和**正在下的那一条**都当场生效（M10m）：先落「已暂停」，再取消执行句柄 ——
    /// 执行器在下一个可停处停下（分片之间 / 当前请求被打断），交回的也是「已暂停」而不是失败；
    /// 半成品按 M10d 的规矩删掉（「继续」时从头下）。
    func pauseDownload(id: String) async {
        await updateDownload(id: id) { DownloadQueue.pausing($0) }
        downloadRunTasks[id]?.cancel()
    }

    /// 继续 / 重试（会重置自动重试额度，见 ``DownloadQueue/retrying(_:)``）。
    func resumeDownload(id: String) async {
        await updateDownload(id: id) { DownloadQueue.retrying($0) }
        startDownloadDriverIfNeeded()
    }

    /// 播放页「下载本集」的接线口：入队 + 立刻开跑，并把结果说清（见 ``DownloadEnqueueOutcome``）。
    ///
    /// 没有站点上下文（直播、临时播放）时**不入队**、老实回 `.unsupported` ——
    /// 空站点 key 会让任务的文件名与去重都失去意义。
    func enqueueDownloadsAndStart(
        _ requests: [DownloadRequest],
        siteKey: String,
        title: String,
        headers: [String: String] = [:]
    ) async -> DownloadEnqueueOutcome {
        guard !siteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unsupported
        }
        let added = await enqueueDownloads(requests, siteKey: siteKey, title: title, headers: headers)
        guard !added.isEmpty else {
            return .alreadyQueued
        }
        startDownloadDriverIfNeeded()
        return .added(added.count)
    }

    /// 还有没有「该跑」的任务：排队中 / 下载中。
    ///
    /// 暂停（用户意愿）、完成、失败（等用户重试）都不算 —— 驱动不该把用户的暂停当成待办。
    var hasPendingDownloads: Bool {
        downloadTasks.contains { $0.status == .waiting || $0.status == .running }
    }

    /// 前台下载驱动（M10h）：入队即启动、回到前台再启动一次，跑到没有可启动的为止。
    ///
    /// 重复调用是安全的：已经在驱动就直接返回（`runDownloadQueue` 自己也有防重入）。
    /// 循环结束条件用「还有没有待办」而不是「这一轮跑掉几条」——
    /// 刚跑完又有人入队（或刚才被并发路径挡着）时会再补一轮，最多两轮。
    func startDownloadDriverIfNeeded() {
        guard downloadDriverTask == nil, hasPendingDownloads else {
            return
        }
        downloadDriverTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer { downloadDriverTask = nil }
            await runDownloadQueue()
            if hasPendingDownloads {
                await runDownloadQueue()
            }
        }
    }

    /// 删掉一条任务，并**连文件一起删**。
    ///
    /// 不删文件会留下「看不见但占着空间」的字节，而「下载管理」页第一眼就是空间占用。
    func removeDownload(id: String) async {
        // 正在下的那条连下载一起停掉：任务都删了，还接着跑完是白占带宽（M10m）。
        downloadRunTasks[id]?.cancel()
        if let task = downloadTasks.first(where: { $0.id == id }) {
            Self.removeDownloadedFiles(of: task, in: downloadDirectory)
        }
        await downloadStore.remove(id: id)
        await synchronizeDownloads()
    }

    /// 清空全部任务（连文件）。
    func clearDownloads() async {
        // 同上：在跑的都叫停。
        for handle in downloadRunTasks.values {
            handle.cancel()
        }
        for task in downloadTasks {
            Self.removeDownloadedFiles(of: task, in: downloadDirectory)
        }
        await downloadStore.clear()
        await synchronizeDownloads()
    }

    /// 跑一轮下载队列，返回这一轮跑掉的任务数。
    ///
    /// 能启动的（``DownloadQueue/nextToStart(_:limit:)``，并发上限也在那边）**并发**跑；
    /// 一轮跑完再看有没有新的可启动（比如失败后回到 `waiting` 的），直到没有为止。
    /// 已经在跑时不重入 —— 否则同一批任务会被起两遍。
    @discardableResult
    func runDownloadQueue() async -> Int {
        guard !isDownloading else {
            return 0
        }
        isDownloading = true
        defer { isDownloading = false }

        var completed = 0
        while true {
            let starting = DownloadQueue.nextToStart(downloadTasks)
            guard !starting.isEmpty else {
                break
            }
            let running = starting.map { $0.transitioning(to: .running) }
            let runner = DownloadRunner(transport: downloadTransport(), directory: downloadDirectory)
            // 一条任务一个句柄（M10m）：暂停 / 删除要能把「正在下的那一条」单独取消，
            // 而 `TaskGroup` 只能整组取消 —— 所以先建句柄，再用组只负责按完成顺序收结果。
            //
            // ⚠️ 建句柄与登记必须在**这一段没有任何 await**：登记之后再让出主线程，
            // 「选好任务 → 落库」之间用户按的暂停就一定找得到句柄（找不到 = 暂停成摆设）。
            // 反过来也**不要**拿 `downloadTasks` 里那条的 status 来判断「它还该不该跑」：
            // M10b 的恢复策略是 `running` 读出来一律降级成 `waiting`（`recoveredStatus`），
            // 拿它当开关永远不成立 —— 曾经因此把同一批任务挑了又跳，`while true` 空转烧 CPU。
            var handles: [(id: String, handle: Task<DownloadRunner.Outcome, Never>)] = []
            for task in running {
                handles.append((task.id, Task { await runner.run(task) }))
            }
            for (id, handle) in handles {
                downloadRunTasks[id] = handle
            }
            // 再落库：万一这之后被杀掉，库里存着 `running`，下次恢复时 M10b 会把它降级回排队，
            // 不会卡住并发位。
            await downloadStore.save(running)
            await synchronizeDownloads()
            await withTaskGroup(of: DownloadRunner.Outcome.self) { group in
                for (_, handle) in handles {
                    group.addTask {
                        await handle.value
                    }
                }
                for await outcome in group {
                    downloadRunTasks[outcome.task.id] = nil
                    await applyDownloadOutcome(outcome)
                    completed += 1
                }
            }
        }
        return completed
    }

    /// 下载用的传输：测试注入优先，否则与站点请求同一套（header / 代理 / 广告拦截口径一致）。
    func downloadTransport() -> HTTPTransport {
        downloadTransportOverride ?? transportForConfiguration()
    }

    /// 收下一条执行结果。
    ///
    /// **只更新还在清单里的任务**：用户中途删掉的那条，把它刚落下的文件也删掉 ——
    /// 否则「删除」之后空间占用不动，看着像没删掉。
    func applyDownloadOutcome(_ outcome: DownloadRunner.Outcome) async {
        guard let current = downloadTasks.first(where: { $0.id == outcome.task.id }) else {
            if let fileURL = outcome.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        // 「旧结果不盖新决定」（M10m）：按**结果的状态**分派 —— 不能拿「当前是不是 running」
        // 当开关（库读回来的 `running` 一律是 `waiting`，见 `recoveredStatus`）。
        // - 取消结果（`.paused`）**不落库**：暂停状态是用户按出来的（``pauseDownload`` 先写
        //   「已暂停」再取消句柄），执行器这趟不带新信息。「读镜像再判断」挡不住它 ——
        //   `downloadStore.save` 是**离 actor 的 await**（非隔离 async 跑在全局执行器上），
        //   两次 save 的落地顺序没有保证：暂停 → 继续写下 `.waiting` 之后，这里迟到的
        //   `.paused` 可能后落库，把 `.waiting` 盖回「已暂停」，任务就停住没人启动了
        //   （M10m 首验二连红就是这个）。不写，就没得抢；
        // - 失败结果不盖暂停：否则会把用户按下的暂停拉回自动重试；
        // - 「已完成」是文件完整落盘的既成事实，永远落库。
        switch outcome.task.status {
        case .paused, .running:
            return
        case .waiting, .failed:
            guard current.status != .paused else {
                return
            }
        case .finished:
            break
        }
        await downloadStore.save(outcome.task)
        await synchronizeDownloads()
    }

    // MARK: - 内部

    /// 改一条任务（找不到、或没变化就不动）。
    func updateDownload(id: String, _ transform: (DownloadTask) -> DownloadTask) async {
        guard let task = downloadTasks.first(where: { $0.id == id }) else {
            return
        }
        let updated = transform(task)
        guard updated != task else {
            return
        }
        await downloadStore.save(updated)
        await synchronizeDownloads()
    }

    /// 「这一集是不是已经下好了」—— 按**远端播放地址**找（M10g）。
    ///
    /// 为什么按地址找而不是按片名 / 集名：播放流程（详情页 / 选集页 / 解析页 / 直播页）拼出来的
    /// `MediaResource` 手上只有地址与 header，片名那些在更外层。而地址是**同一份** ——
    /// 任务当初就是用它入的队（`DownloadRequest.url`）。
    ///
    /// 两处必须挡住的情况：
    /// - 只认 `finished`：半截文件播不了，而「记录说下好了、文件被系统清理掉了」也得挡住
    ///   （下面前缀扫目录就是为它）；
    /// - 同一地址可能有多个任务（不同站点），逐个找，找到第一个真有文件的。
    func localDownloadedFile(forRemoteURL url: String) -> URL? {
        guard !url.isEmpty else {
            return nil
        }
        for task in downloadTasks where task.status == .finished && task.url == url {
            if let file = Self.downloadedFile(of: task, in: downloadDirectory) {
                return file
            }
        }
        return nil
    }

    /// 找一条任务落下的文件（按前缀扫目录，理由同 ``removeDownloadedFiles(of:in:)``：
    /// 后缀可能是 `.ts` / `.mp4` / 执行器从地址认出来的其它）。
    static func downloadedFile(of task: DownloadTask, in directory: URL) -> URL? {
        let prefix = DownloadTask.sanitized("\(task.fileNameBase) · \(task.siteKey)")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return directory.appendingPathComponent(name)
    }

    /// 内存里的顺序与库保持一致（都按创建时间），免得界面顺序忽然跳。
    static func sortedDownloadTasks(_ tasks: [DownloadTask]) -> [DownloadTask] {
        tasks.sorted { $0.createdAt < $1.createdAt }
    }

    /// 删掉一条任务对应的文件。
    ///
    /// 文件名由执行器生成（`fileNameBase · 站点key` + 后缀），这里按**前缀扫目录**删：
    /// 后缀可能是 `.ts` / `.mp4`（甚至 `DownloadRunner.suffix(for:)` 认出来的其它），
    /// 写死后缀会漏删。
    static func removeDownloadedFiles(of task: DownloadTask, in directory: URL) {
        let prefix = DownloadTask.sanitized("\(task.fileNameBase) · \(task.siteKey)")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in contents where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
