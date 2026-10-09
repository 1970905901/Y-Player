@testable import CatVodCore
import Testing

@Suite("下载任务：标识 / 进度 / 状态机 / 落盘名")
struct DownloadTaskTests {
    private func task(
        site: String = "wogg",
        title: String = "某剧",
        episode: String = "第 1 集",
        line: String = "线路一",
        url: String = "https://cdn.example/1.m3u8"
    ) -> DownloadTask {
        DownloadTask(siteKey: site, title: title, episode: episode, line: line, url: url)
    }

    // MARK: - 标识

    @Test("标识：同一集同一线路稳定；换线路或换站点就是另一个任务")
    func identityStability() {
        #expect(task().id == task().id)
        #expect(task().id != task(line: "线路二").id)
        #expect(task().id != task(site: "other").id)
        #expect(task().id != task(episode: "第 2 集").id)
    }

    @Test("标识：分隔符被转义，片名里带 `|` 也不会跟别的集撞键")
    func identityEscapesSeparator() {
        // 直接拼的话这两组会得到同一个键（"a|b|c" 与 "a|b|c"）。
        let left = task(title: "a|b", episode: "c").id
        let right = task(title: "a", episode: "b|c").id
        #expect(left != right)
        // 转义本身也要稳定（同一个输入两次调用一样）
        #expect(left == task(title: "a|b", episode: "c").id)
    }

    // MARK: - 进度

    @Test("进度：没有总量时是 nil（不知道还剩多少），不是 0")
    func progressWithoutExpectedBytes() {
        var item = task()
        item.receivedBytes = 1024
        #expect(item.progress == nil)
    }

    @Test("进度：按总量算比例，超出总量夹到 1")
    func progressRatio() {
        var item = task()
        item.expectedBytes = 1000
        item.receivedBytes = 250
        #expect(item.progress == 0.25)

        item.receivedBytes = 4000
        #expect(item.progress == 1)
    }

    @Test("自动重试额度：只有 failed 且没用完时为真")
    func autoRetryBudget() {
        var item = task()
        item.status = .running
        #expect(!item.canAutoRetry)

        item.status = .failed
        #expect(item.canAutoRetry)

        item.retryCount = DownloadTask.retryLimit
        #expect(!item.canAutoRetry)
    }

    // MARK: - 状态机

    @Test("已完成的只能还是已完成：要重下就是新任务")
    func finishedIsTerminal() {
        let done = task().transitioning(to: .running).transitioning(to: .finished)
        #expect(done.status == .finished)
        #expect(!DownloadTask.canTransition(from: .finished, to: .waiting))
        #expect(!DownloadTask.canTransition(from: .finished, to: .running))
        #expect(done.transitioning(to: .waiting).status == .finished)
    }

    @Test("排队中的不能直接跳到已完成：跳过了「下载中」这一步就是逻辑错")
    func waitingCannotFinishDirectly() {
        #expect(!DownloadTask.canTransition(from: .waiting, to: .finished))
        #expect(task().transitioning(to: .finished).status == .waiting)
    }

    @Test("非法迁移原地返回；合法迁移会清掉失败原因，转入 failed 时保留")
    func transitioningNotes() {
        var failed = task()
        failed.status = .failed
        failed.failureReason = "连接超时"

        // 回 waiting 是合法迁移 → 原因被清掉（重试之后那句话就过期了）
        let retried = failed.transitioning(to: .waiting)
        #expect(retried.status == .waiting)
        #expect(retried.failureReason.isEmpty)

        // 原地返回：连失败原因都不该被动
        let stuck = failed.transitioning(to: .finished)
        #expect(stuck == failed)
    }

    // MARK: - 落盘名

    @Test("文件名清洗：路径分隔符与保留字符全换掉，路径穿越的名字也不成立")
    func sanitizedDropsUnsafeCharacters() {
        let raw = "../../etc/passwd"
        let cleaned = DownloadTask.sanitized(raw)
        #expect(!cleaned.contains("/"))
        #expect(!cleaned.hasPrefix("."))

        let reserved = DownloadTask.sanitized("a:b?c*d\"e<f>g|h\\i")
        for character in [":", "?", "*", "\"", "<", ">", "|", "\\", "/"] {
            #expect(!reserved.contains(character))
        }
    }

    @Test("文件名清洗：折叠空白、空结果回落、超长按字符截断")
    func sanitizedFoldsAndLimits() {
        #expect(DownloadTask.sanitized("  多余   空白  ") == "多余 空白")
        #expect(DownloadTask.sanitized("///") == "未命名")
        #expect(DownloadTask.sanitized("   ") == "未命名")

        let long = String(repeating: "字", count: 200)
        let limited = DownloadTask.sanitized(long, limit: 10)
        #expect(limited.count == 10)
    }

    @Test("落盘名：片名 · 集名（带线路），空的部件不留下多余分隔符")
    func fileNameBase() {
        #expect(task().fileNameBase == "某剧 · 第 1 集 · 线路一")
        #expect(task(line: "").fileNameBase == "某剧 · 第 1 集")
    }
}
