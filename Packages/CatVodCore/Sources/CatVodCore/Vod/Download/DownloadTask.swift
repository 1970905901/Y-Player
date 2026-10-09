import Foundation

/// 一次离线下载任务（M10a）。
///
/// ⚠️ **上游没有参考实现**（`Tools/out` 的 `ref-*.java` 里没有任何 Download 相关类），
/// 所以这一块是**本项目自己的设计**，不是照抄协议。正因为没有上游可对，口径必须全部写在类型里、
/// 并由单测钉住 —— 「照着上游抄」这条退路在这里不存在。
///
/// 它与「播放进度 / 收藏」那种记录的区别：**它是可执行的** —— 有地址、有进度、有状态机，
/// 所以「哪些状态能互相变」本身就是规则（``canTransition(from:to:)``），不是随手赋值。
///
/// 分层（M10a 只做第一层，其余按 M08 / M09 的节奏往下走）：
/// 1. **本文件 + ``DownloadQueue``**：任务与队列的纯逻辑（无 IO、无网络、可单测）；
/// 2. 落库（GRDB，与播放进度/收藏同一套）；
/// 3. 传输（分片下载 + 断点续传）；
/// 4. 「本地播放地址接管」：已下载的集在详情页改成播本地文件；
/// 5. 界面（详情页的下载按钮 + 「下载管理」的任务列表）。
public struct DownloadTask: Sendable, Hashable, Identifiable {
    /// 任务状态。
    ///
    /// `waiting` 与 `paused` 刻意分开：前者是「排队等并发位」，后者是「用户要求的」——
    /// 界面上一个说「等待中」一个说「已暂停」，而且用户按过暂停之后不该被自动放回队列。
    public enum Status: String, Sendable, CaseIterable, Hashable {
        /// 排队中（等并发位）。
        case waiting
        /// 下载中。
        case running
        /// 用户暂停。
        case paused
        /// 已完成（文件已落地）。
        case finished
        /// 失败（可重试）。
        case failed
    }

    /// 站点 `key`（换源之后就是另一个任务了：地址与 header 都不一样）。
    public var siteKey: String
    /// 片名。
    public var title: String
    /// 集名（「第 3 集」这种；上游没有统一格式，原样存）。
    public var episode: String
    /// 线路名（协议里的 `flag`）。
    public var line: String
    /// 下载地址（播放地址；HLS 时是清单地址，分片由传输层展开）。
    public var url: String
    /// 请求头（站点 header + 结果 header，与播放同一套合并口径）。
    public var headers: [String: String]
    /// 状态。
    public var status: Status
    /// 期望字节数；`0` = 上游没给 `Content-Length`（进度未知）。
    public var expectedBytes: Int64
    /// 已下载字节数。
    public var receivedBytes: Int64
    /// 失败原因（面向用户的一句话）；非失败态为空。
    public var failureReason: String
    /// 已经重试过几次。
    public var retryCount: Int
    /// 创建时间（队列按它排先后）。
    public var createdAt: Date

    public init(
        siteKey: String,
        title: String,
        episode: String,
        line: String = "",
        url: String,
        headers: [String: String] = [:],
        status: Status = .waiting,
        expectedBytes: Int64 = 0,
        receivedBytes: Int64 = 0,
        failureReason: String = "",
        retryCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.siteKey = siteKey
        self.title = title
        self.episode = episode
        self.line = line
        self.url = url
        self.headers = headers
        self.status = status
        self.expectedBytes = expectedBytes
        self.receivedBytes = receivedBytes
        self.failureReason = failureReason
        self.retryCount = retryCount
        self.createdAt = createdAt
    }

    /// 稳定标识：`站点|片名|集名|线路`（各部分先转义）。
    ///
    /// 为什么不用 URL 当标识：换源 / 换线路之后地址会变，而「这一集的这一条线路」没变 ——
    /// 去重必须按它算，否则同一集会被下两遍。
    public var id: String {
        Self.identity(siteKey: siteKey, title: title, episode: episode, line: line)
    }

    /// 拼标识。**各部分先转义再拼**：片名里出现分隔符时（`"a|b"` + `"c"` 与 `"a"` + `"b|c"`）
    /// 直接拼会得到同一个键，两集就被当成同一集了。
    public static func identity(siteKey: String, title: String, episode: String, line: String) -> String {
        [siteKey, title, episode, line]
            .map { $0.replacingOccurrences(of: identitySeparator, with: identityEscape) }
            .joined(separator: identitySeparator)
    }

    /// 标识分隔符与它的转义写法。
    ///
    /// 转义用 `\\|`：`\` 在文件名里也要被清掉（``sanitized(_:limit:fallback:)``），两处规则一致，
    /// 读代码时不用记两套。
    static let identitySeparator = "|"
    static let identityEscape = "\\|"

    // MARK: - 进度与状态

    /// 已下载比例；`nil` = 还不知道总量（上游没给 `Content-Length`）。
    ///
    /// 用可选值而不是「0 或 1」：`0` 会让内联进度条看起来「卡在开头」，
    /// 而真实情况是「不知道还剩多少」—— 界面该显示不确定态。
    public var progress: Double? {
        guard expectedBytes > 0 else {
            return nil
        }
        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }

    /// 是否已落地（终态）。
    public var isFinished: Bool {
        status == .finished
    }

    /// 是否还有**自动**重试的额度（手动重试不受它限制，见 ``DownloadQueue/retrying(_:)``）。
    public var canAutoRetry: Bool {
        status == .failed && retryCount < Self.retryLimit
    }

    /// 重试上限：超过就停在 `failed`，由用户手动再来。
    ///
    /// 自动无限重试会把流量和电耗在坏源上 —— 而且用户往往看不出「它在偷偷重试」。
    public static let retryLimit = 3

    /// 状态能不能这么变。允许的迁移（刻意收窄）：
    ///
    /// - `waiting` → `running`（拿到并发位）/ `paused`（取消排队）/ `failed`（排队期间地址就没了）
    /// - `running` → `finished` / `paused` / `failed` / `waiting`（退回复位：重试或让位）
    /// - `paused` → `waiting`（用户继续）/ `failed`
    /// - `failed` → `waiting`（重试）/ `paused`
    /// - `finished` → 只能还是 `finished`：要重下就是一个新任务，
    ///   否则「已完成」会被某条路径偷偷改回「下载中」，界面上文件明明在、却显示在下载
    public static func canTransition(from old: Status, to new: Status) -> Bool {
        if old == new {
            return true
        }
        switch (old, new) {
        case (.waiting, .running), (.waiting, .paused), (.waiting, .failed):
            return true
        case (.running, .finished), (.running, .paused), (.running, .failed), (.running, .waiting):
            return true
        case (.paused, .waiting), (.paused, .failed):
            return true
        case (.failed, .waiting), (.failed, .paused):
            return true
        default:
            return false
        }
    }

    /// 迁移状态；非法迁移**原地返回**。失败原因只在离开 `failed` 时清掉。
    public func transitioning(to new: Status) -> DownloadTask {
        guard Self.canTransition(from: status, to: new) else {
            return self
        }
        var copy = self
        copy.status = new
        if new != .failed {
            copy.failureReason = ""
        }
        return copy
    }

    // MARK: - 落盘名

    /// 文件名长度上限（按字符数）。APFS 的上限是 255 **字节**，中文一个字三字节，
    /// 所以按字符截断要留足余量给后缀。
    public static let fileNameLimit = 60

    /// 清出一个能当文件名的字符串。
    ///
    /// 这类函数的价值全在**边界**上，所以口径写细：
    /// - 换掉路径分隔符与文件系统保留字符（`/` `\` `:` `?` `*` `"` `<` `>` `|`）与控制字符；
    /// - 折叠连续空白、去掉首尾空白，并去掉**开头的点**（`..` 这种名字能跳出目录）；
    /// - 结果为空 → 回落 `fallback`（否则会得到一个看不见名字的文件）；
    /// - 截断按字符数（不是字节数：按字节截会切出半个字）。
    public static func sanitized(_ raw: String, limit: Int = fileNameLimit, fallback: String = "未命名") -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?*\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        var cleaned = ""
        for scalar in raw.unicodeScalars {
            if illegal.contains(scalar) {
                cleaned.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        cleaned = String(cleaned.prefix(max(1, limit))).trimmingCharacters(in: .whitespaces)
        // 去掉开头的点**放在折叠与截断之后**：先把 `../..` 变成 `.. ..` 再逐点剥离，
        // 否则前面那一步又会把点重新留在开头（`..` 这种名字能跳出目录）。
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// 落盘用的文件名（**不含后缀**）：`片名 · 集名`，有线路名时带上线路。
    ///
    /// 后缀交给传输层：HLS 下完落地是 `.mp4` 还是 `.ts` 只有它知道，这里不替它猜。
    public var fileNameBase: String {
        let parts = [title, episode, line].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Self.sanitized(parts.joined(separator: " · "))
    }
}
