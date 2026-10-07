import CatVodCore
import CatVodNet
import Foundation

/// `type=4` 聚合解析的 JSON 侧执行器：逐条对齐上游 `ParseJob.superParse` 里 `jsonParse` 的部分。
///
/// 语义要点（与上游一致）：
/// - 成员**并发**跑，谁先给出合法地址算谁（上游 `onParseSuccess` 的 `done.compareAndSet` 保证只成功一次）；
/// - 单个成员失败**不致命**（上游 `jsonParse(item, webUrl, false)` 的 `fatal = false`），要等其它成员；
/// - 全部失败才算失败（上游 `latch.await()` 之后 `onParseError()`），并且要把每个成员的原因带出来，
///   便于用户对着源排查「是哪一个解析器挂了」。
///
/// `type=0` 的成员**不在这里**：它由 Web 嗅探视图并行上报，调用方拿到任意一边的成功即可
/// （对齐上游「WebView 回调 + CountDownLatch」的双通道）。
public struct AggregateParser: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 执行聚合计划里的 JSON 成员。
    ///
    /// - Parameters:
    ///   - plan: 由 ``AggregateParsePlan`` 按线路分好组的解析器。
    ///   - webURL: 待解析地址（与 ``ParseJob/webURL`` 同义）。
    ///   - headers: 结果级 header（成员自身 `ext.header` 为空时生效）。
    ///   - click: 点击脚本（Web 侧用；JSON 侧原样带下去，便于两个通道用同一份参数）。
    ///   - timeout: 单个成员的超时（秒）。
    public func parse(
        _ plan: AggregateParsePlan,
        webURL: String,
        headers: [String: String] = [:],
        click: String = "",
        timeout: TimeInterval = ParseJobResolver.defaultTimeout
    ) async throws -> ParsedPlayback {
        let jobs = plan.jsonJobs(webURL: webURL, headers: headers, click: click, timeout: timeout)
        guard !jobs.isEmpty else {
            throw CatVodError.unsupported(
                feature: "type=4 聚合解析",
                reason: "该线路没有可用的 type=1 解析器"
                    + (plan.opensWebSniffer ? "（配置里只有 type=0，需要 Web 嗅探）" : "（配置里既没有 type=1 也没有 type=0）")
            )
        }
        return try await race(jobs)
    }

    // MARK: - 内部

    /// 一个成员的结局。
    ///
    /// 刻意不携带 `Error` 本身：`Error` 不保证 `Sendable`，跨任务边界只传可读文案。
    private enum MemberOutcome: Sendable {
        case parsed(ParsedPlayback)
        case failed(name: String, reason: String)
    }

    /// 竞速的总体结局。
    private enum RaceOutcome: Sendable {
        case winner(ParsedPlayback)
        case allFailed(reasons: [String])
    }

    /// 并发跑所有成员，第一个成功即返回并取消其余成员。
    private func race(_ jobs: [ParseJob]) async throws -> ParsedPlayback {
        let parser = JSONParser(transport: transport)
        let outcome = await withTaskGroup(of: MemberOutcome.self, returning: RaceOutcome.self) { group in
            for job in jobs {
                group.addTask {
                    await Self.run(parser: parser, job: job)
                }
            }
            var failures: [String] = []
            while let item = await group.next() {
                if case let .parsed(playback) = item {
                    group.cancelAll()
                    return .winner(playback)
                }
                if case let .failed(name, reason) = item {
                    failures.append("\(name)：\(reason)")
                }
            }
            return .allFailed(reasons: failures.sorted())
        }
        switch outcome {
        case let .winner(playback):
            return playback
        case let .allFailed(reasons):
            throw CatVodError.parseFailed(
                flag: jobs[0].flag,
                reason: "\(jobs.count) 个解析器都没能给出地址 —— \(reasons.joined(separator: "；"))"
            )
        }
    }

    /// 跑一个成员，把结局压成可读且 `Sendable` 的 ``MemberOutcome``。
    private static func run(parser: JSONParser, job: ParseJob) async -> MemberOutcome {
        do {
            return .parsed(try await parser.parse(job))
        } catch {
            return .failed(name: displayName(job), reason: message(for: error))
        }
    }

    /// 成员失败原因：优先用 ``CatVodError`` 的可读描述。
    private static func message(for error: any Error) -> String {
        if let catVod = error as? CatVodError {
            return catVod.errorDescription ?? String(describing: catVod)
        }
        return String(describing: error)
    }

    /// 日志/错误里的成员名（匿名解析器退回 `type=N`）。
    private static func displayName(_ job: ParseJob) -> String {
        job.parser.name.isEmpty ? "type=\(job.parser.type)" : job.parser.name
    }
}
