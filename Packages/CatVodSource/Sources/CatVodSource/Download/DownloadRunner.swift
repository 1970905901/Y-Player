import CatVodCore
import CatVodNet
import Foundation

/// 离线下载的执行器（M10d）：把一个 ``DownloadTask`` 真的下成文件。
///
/// 分层（M10a 定的）：任务与队列的**规则**在 Core、存储在 M10b、清单展开在 M10c，
/// **这里只负责「照着做」** —— 拉地址 → 是 HLS 清单就展开 → 逐片下载追加写进同一个文件 →
/// 用 ``DownloadQueue`` 推进状态。
///
/// 四处刻意的做法：
/// 1. **一个任务一个文件**（`fileNameBase` + 后缀），片段按顺序**追加写**：TS / fMP4 片段
///    拼接起来本身就是可播的文件（fMP4 靠 init 片在最前，那是 M10c 的职责）；
/// 2. **每片都带同一套 header**：站点鉴权多半挂在 header 上，漏一片就是 403；
/// 3. **失败即停**：一片失败就按 ``DownloadQueue`` 的规则回退，**不跳过接着下** ——
///    那样会得到一个中间少一段的文件，而且没有任何迹象；
/// 4. **半途停下留着半成品，下次接着下**（M10n）：账目 = ``DownloadTask/completedSegments``
///    + 清单前缀指纹（``HLSManifest/segmentFingerprint(prefix:)``），都存在任务里。
///    文件按账目的字节数对账（多出来的尾巴截掉）；指纹对不上就整份重下 —— 绝不硬拼。
///    直链不做续下（一整块一次写，账目无处可对）；
/// 5. **加密片段（AES-128）先解密再写**（M10k）：密钥按 URI 缓存（同一份清单同一把 key 只取一次）、
///    IV 用解析器兜好的那个；密钥 / IV / 密文任何一步不对就**直接报错**，绝不把密文写进成品；
/// 6. **字节范围片段发 `Range` 再拼**（M10l）：同一条 URI 上的多段靠范围区分；
///    上游没按范围回（非 206）或回的字节数对不上就**报错**，不把整段文件当一段拼进去。
/// 7. **暂停 = 取消执行句柄**（M10m）：上层暂停 / 删除一条正在下的任务时取消它的 `Task`，
///    这里在分片之间（`Task.checkCancellation`）与当前请求被中断时停下，回「已暂停」而不是失败；
///    停下的账目见第 4 条（半成品留着、下次接着下）。
///
/// 不持有 `FileManager`：`FileManager` 在 Swift 6 下不是 `Sendable`，各方法内部用 `.default`
/// 反而更省事（与 ``StorageSpace`` 把 fileManager 当参数传是同一个理由）。
public struct DownloadRunner: Sendable {
    /// 一次执行的结果。
    public struct Outcome: Sendable {
        /// 更新后的任务（失败时也已按重试规则落好状态与原因）。
        public var task: DownloadTask
        /// 落盘位置；失败时为 nil。
        public var fileURL: URL?
    }

    private let transport: HTTPTransport
    private let directory: URL

    /// - Parameter directory: 落盘目录（App 里用 `AppModel.downloadDirectory`）。
    public init(transport: HTTPTransport, directory: URL) {
        self.transport = transport
        self.directory = directory
    }

    /// 跑一个任务（一般是 ``DownloadQueue/nextToStart(_:limit:)`` 挑出来的那条）。
    ///
    /// **不抛错**：失败写进返回的任务 —— 状态由 ``DownloadQueue/applying(failure:to:)`` 决定
    /// （还在额度内就是「排队中」，用完就是「失败」）。执行层不管重试策略，只回答「这次成没成」。
    ///
    /// **被取消**（用户暂停，见 `AppModel.pauseDownload`）不算失败：回 `.paused`，
    /// 不乱动重试额度、不写失败原因 —— 恢复由用户点「继续」。
    ///
    /// 失败 / 被取消时，返回的任务带着**账目**（``DownloadTask/completedSegments`` + 指纹 +
    /// 字节数）：半成品留在原地，下次（重试 / 继续）从账目那一片接着下（M10n）。
    ///
    /// - Parameter onProgress: 每收下一片报一次「累计字节 / 期望字节」；总量未知时期望传 0。
    public func run(
        _ task: DownloadTask,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async -> Outcome {
        let running = task.transitioning(to: .running)
        do {
            let result = try await download(running, onProgress: onProgress)
            var done = running.transitioning(to: .finished)
            done.receivedBytes = result.received
            done.expectedBytes = result.expected
            // 完成 = 没有可续的：账目清零（续下只在半途有意义）。
            done.completedSegments = 0
            done.resumeFingerprint = ""
            return Outcome(task: done, fileURL: result.fileURL)
        } catch {
            var stopped = running
            var underlying = error
            if let partial = error as? PartialStop {
                // 半途停下的账目：跑到第几片、文件里有多少字节、指纹是什么。
                stopped.completedSegments = partial.completedSegments
                stopped.resumeFingerprint = partial.fingerprint
                stopped.receivedBytes = partial.receivedBytes
                stopped.expectedBytes = partial.expectedBytes
                underlying = partial.underlying
            }
            // 句柄被取消 = 用户暂停 / 删除（AppModel 只在这两处取消它）。
            // 判据用 `Task.isCancelled` 而不是错误类型：`URLSessionTransport` 会把底层的
            // `CancellationError` 包成 `CatVodError.network`，错误类型到这一层已经不可信。
            if Task.isCancelled {
                return Outcome(task: DownloadQueue.pausing(stopped), fileURL: nil)
            }
            return Outcome(
                task: DownloadQueue.applying(failure: Self.reason(for: underlying), to: stopped),
                fileURL: nil
            )
        }
    }

    // MARK: - 内部

    private struct FetchDone {
        var received: Int64
        var expected: Int64
        var fileURL: URL
        /// 文件里此刻**完整**的片段数（含续下带进来的基数；M10n）。
        var completedSegments: Int
        /// 这几片的清单前缀指纹（M10n）。
        var fingerprint: String
    }

    /// 半途停下（失败 / 被取消）的账目（M10n）。
    ///
    /// 为什么包一层错误：账目是 `writeSegments` 的局部变量长出来的，抛错是它唯一能出去的通道 ——
    /// 不能再像 M10d 那样「失败就把半成品删了」（那样续下无从谈起）。
    private struct PartialStop: Error {
        var completedSegments: Int
        var receivedBytes: Int64
        var expectedBytes: Int64
        var fingerprint: String
        var underlying: Error
    }

    /// 续下的起点（M10n）。`segment == 0` = 从头下（没有可用账目）。
    struct ResumeStart: Equatable {
        var segment: Int
        var receivedBytes: Int64
        var expectedBytes: Int64

        /// 从头下。
        static let fresh = ResumeStart(segment: 0, receivedBytes: 0, expectedBytes: 0)
    }

    private func download(
        _ task: DownloadTask,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> FetchDone {
        // 已经取消（暂停落在开跑之前）：一个请求都不发。
        try Task.checkCancellation()
        let first = try await fetch(task.url, task: task)
        let manifest = HLSManifestParser.parse(text: first.text, baseURL: task.url)

        // 不是清单：响应体本身就是内容（直链 mp4 / flv 都走这条），一次写完收工。
        if !manifest.hasContent {
            let fileURL = try write(Data(first.body), as: task, suffix: Self.suffix(for: task.url))
            let size = Int64(first.body.count)
            onProgress?(size, size)
            return FetchDone(received: size, expected: size, fileURL: fileURL, completedSegments: 0, fingerprint: "")
        }

        // 主清单：按带宽最高的变体再取一次媒体清单（M10c 的选路规则）。
        var media = manifest
        if manifest.isMaster {
            guard let variant = manifest.bestVariant else {
                throw CatVodError.parseFailed(flag: task.episode, reason: "主清单里没有可用的变体")
            }
            let response = try await fetch(variant.url, task: task)
            media = HLSManifestParser.parse(text: response.text, baseURL: variant.url)
        }
        guard media.isDownloadable else {
            throw CatVodError.unsupported(feature: "离线下载", reason: Self.refusalReason(media))
        }
        guard !media.segments.isEmpty else {
            throw CatVodError.parseFailed(flag: task.episode, reason: "清单里没有可下载的片段")
        }

        let target = try fileURL(for: task, suffix: media.hasInitializationSegment ? "mp4" : "ts")
        var start = Self.resumeStart(for: task, manifest: media, fileSize: Self.fileSize(of: target))
        if start == .fresh {
            // 从头下：残留（账目对不上的半成品）清掉，建一个空文件。
            try? FileManager.default.removeItem(at: target)
            _ = FileManager.default.createFile(atPath: target.path, contents: nil)
        } else {
            // 续下：文件按账目的字节数对账（多出来的尾巴是上次写了一半的片段，截掉重写）。
            do {
                try Self.trim(target, to: start.receivedBytes)
            } catch {
                // 截不动（文件没了 / 没权限）：退回从头下，别硬拼。
                try? FileManager.default.removeItem(at: target)
                _ = FileManager.default.createFile(atPath: target.path, contents: nil)
                start = .fresh
            }
        }
        return try await writeSegments(media, to: target, start: start, task: task, onProgress: onProgress)
    }

    // MARK: - 取与写

    /// 一次取回的响应（正文 + 长度 + 文本视图）。
    private struct Fetch {
        var body: Data
        var contentLength: Int64?

        var text: String {
            String(data: body, encoding: .utf8) ?? ""
        }
    }

    /// 一次执行写下的结果。
    // `Written` 曾是与 `FetchDone` **字段完全相同**的孪生结构（M10 写下时两处各自定义）。
    // 结果 `download` 的 HLS 分支返回 `Written`、声明却是 `FetchDone` —— 编译不过，
    // 而 CatVodSource 直到 2026-10-09 才第一次被编译（CI 的 build 作业一直 needs core-tests 而 skipped）。
    // 合并成一个 `FetchDone`，两处都用它：字段一样的两个类型，迟早会对不上。

    private func fetch(
        _ url: String,
        task: DownloadTask,
        range: HLSManifest.SegmentRange? = nil
    ) async throws -> Fetch {
        // `URL(string:)` 对任意文本都可能返回 nil 也可能返回非 nil，必须自己查 scheme/host（M06c 踩过一次）。
        guard let target = URL(string: url), target.scheme != nil, target.host != nil else {
            throw CatVodError.parseFailed(
                flag: task.episode,
                reason: "下载地址无法构造 URL：\(url.prefix(120))"
            )
        }
        var headers = task.headers
        if let range {
            headers["Range"] = "bytes=\(range.offset)-\(range.offset + range.length - 1)"
        }
        let request = HTTPRequest(url: target, method: .get, headers: headers)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: url,
                reason: "下载「\(task.episode)」返回非 2xx"
            )
        }
        if let range {
            // 范围请求的两个硬检查：状态必须是 206（不是 206 = 上游忽略了 Range，回来的多半是整段文件），
            // 回来的字节数必须与范围一致 —— 任一不对就报错，拼错了看不出来。
            guard response.status == 206 else {
                throw CatVodError.unsupported(
                    feature: "离线下载",
                    reason: "上游不支持按字节范围取片段（返回 \(response.status)，不是 206）"
                )
            }
            guard response.body.count == range.length else {
                throw CatVodError.parseFailed(
                    flag: task.episode,
                    reason: "字节范围片段长度不符：要 \(range.length) 字节，回来 \(response.body.count) 字节"
                )
            }
        }
        return Fetch(body: response.body, contentLength: Self.contentLength(response.headers))
    }

    /// `Content-Length`（不区分大小写；取不到 = nil —— 那时进度就是「未知」）。
    static func contentLength(_ headers: [String: String]) -> Int64? {
        for (key, value) in headers where key.lowercased() == "content-length" {
            if let length = Int64(value.trimmingCharacters(in: .whitespaces)), length >= 0 {
                return length
            }
        }
        return nil
    }

    /// 从 `start` 开始逐片下载并追加写（加密片段先解密再写，M10k；续下见 M10n）。
    ///
    /// 一次打开文件、追加到底：每片都开关一次文件，在几百片的长剧集上会多出几百次系统调用。
    /// 失败 / 被取消时抛 ``PartialStop``（带账目），**不删文件** —— 下次从账目那一片接着下。
    private func writeSegments(
        _ manifest: HLSManifest,
        to fileURL: URL,
        start: ResumeStart,
        task: DownloadTask,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> FetchDone {
        var received = start.receivedBytes
        var expected = start.expectedBytes
        // 同一份清单里同一把 key 只取一次（密钥按 URI 缓存）。
        var keys: [String: Data] = [:]
        // 续下时上一段账目可能就是「未知」（0）：保持未知，别把 0 说成一个准确的数。
        var expectedKnown = start.segment == 0 || start.expectedBytes > 0
        var written = 0
        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            // ⚠️ 续下时文件是**已有**的，而 `FileHandle(forWritingTo:)` 的写指针在 0 ——
            // 不 seek 到末尾就会从头覆盖（老的「新建空文件」路径没有这个问题，所以以前不用 seek）。
            try handle.seekToEnd()
            for index in start.segment ..< manifest.segments.count {
                // 暂停的停止点：上一片取完 / 写完就停，不接着取下一片。
                try Task.checkCancellation()
                let range = manifest.segmentRanges.indices.contains(index) ? manifest.segmentRanges[index] : nil
                let piece = try await fetch(manifest.segments[index], task: task, range: range)
                var body = piece.body
                if manifest.segmentKeys.indices.contains(index), let key = manifest.segmentKeys[index] {
                    body = try await decrypt(body, key: key, task: task, cache: &keys)
                }
                try handle.write(contentsOf: body)
                received += Int64(body.count)
                if let length = piece.contentLength {
                    expected += length
                } else {
                    expectedKnown = false
                }
                written += 1
                onProgress?(received, expectedKnown ? expected : 0)
            }
        } catch {
            try? handle.close()
            let completed = start.segment + written
            throw PartialStop(
                completedSegments: completed,
                receivedBytes: received,
                expectedBytes: expectedKnown ? expected : 0,
                fingerprint: manifest.segmentFingerprint(prefix: completed),
                underlying: error
            )
        }
        try handle.close()
        let completed = start.segment + written
        return FetchDone(
            received: received,
            expected: expectedKnown ? expected : 0,
            fileURL: fileURL,
            completedSegments: completed,
            fingerprint: manifest.segmentFingerprint(prefix: completed)
        )
    }

    /// 解一段密文（`AES-128`）：密钥按 URI 缓存；任何一步不对都**直接报错**（绝不把密文写进成品）。
    private func decrypt(
        _ body: Data,
        key: HLSManifest.SegmentKey,
        task: DownloadTask,
        cache: inout [String: Data]
    ) async throws -> Data {
        guard key.method.uppercased() == "AES-128" else {
            throw CatVodError.unsupported(feature: "离线下载", reason: "暂不支持的加密方式：\(key.method)")
        }
        guard !key.uri.isEmpty else {
            throw CatVodError.parseFailed(flag: task.episode, reason: "清单里的 #EXT-X-KEY 没有密钥地址")
        }
        guard let iv = key.ivBytes() else {
            throw CatVodError.parseFailed(
                flag: task.episode,
                reason: "清单里的 IV 不是合法的十六进制：\(key.iv.prefix(40))"
            )
        }
        let secret: Data
        if let cached = cache[key.uri] {
            secret = cached
        } else {
            let response = try await fetch(key.uri, task: task)
            guard response.body.count == 16 else {
                throw CatVodError.parseFailed(
                    flag: task.episode,
                    reason: "密钥长度不是 16 字节（\(response.body.count)）：\(key.uri)"
                )
            }
            cache[key.uri] = response.body
            secret = response.body
        }
        guard let plain = AES128CBC.decrypt(body, key: secret, iv: iv) else {
            throw CatVodError.parseFailed(flag: task.episode, reason: "片段解密失败（密钥或 IV 不对）")
        }
        return plain
    }

    /// 落盘位置（不建文件）。
    ///
    /// 文件名里带上**站点 key**：不同站点可能有同名同集的剧，不带就会互相覆盖
    /// （`fileNameBase` 只由片名 / 集名 / 线路拼成）。
    private func fileURL(for task: DownloadTask, suffix: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = DownloadTask.sanitized("\(task.fileNameBase) · \(task.siteKey)")
        return directory.appendingPathComponent(base).appendingPathExtension(suffix)
    }

    /// 建一个空文件并返回位置（直链那条路径用；HLS 的续下自己管文件）。
    private func makeFile(for task: DownloadTask, suffix: String) throws -> URL {
        let url = try fileURL(for: task, suffix: suffix)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// 能不能接着上次下（M10n）：账目 + 文件大小 + 清单前缀指纹，三者都对得上才续。
    ///
    /// 任何一条对不上都**从头下**（宁可重下，也不拼出一个看不出来的错文件）：
    /// - 没有账目（`completedSegments == 0` / 指纹为空）；
    /// - 半成品文件没了，或比账目还短（字节丢了，接不上）；
    /// - 账目的片数比这份清单还多（清单换了 / 变短了）；
    /// - 前几片的指纹对不上（清单变过：换源 / 重新转码 / 顺序变了）。
    static func resumeStart(for task: DownloadTask, manifest: HLSManifest, fileSize: Int64?) -> ResumeStart {
        guard task.completedSegments > 0, !task.resumeFingerprint.isEmpty else {
            return .fresh
        }
        guard let fileSize, fileSize >= task.receivedBytes else {
            return .fresh
        }
        guard task.completedSegments <= manifest.segments.count else {
            return .fresh
        }
        guard manifest.segmentFingerprint(prefix: task.completedSegments) == task.resumeFingerprint else {
            return .fresh
        }
        return ResumeStart(
            segment: task.completedSegments,
            receivedBytes: task.receivedBytes,
            expectedBytes: task.expectedBytes
        )
    }

    /// 文件现在多大（不存在 = nil）。
    static func fileSize(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// 把文件截到账目长度：多出来的尾巴是上次写了一半的片段（进程被杀 / 写失败），
    /// 截掉重写那一片 —— 这是「账目 = 完整片段」这条口径的兜底。
    static func trim(_ url: URL, to size: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    /// 一次性写一个文件（直链那条路径）。
    private func write(_ data: Data, as task: DownloadTask, suffix: String) throws -> URL {
        let url = try makeFile(for: task, suffix: suffix)
        try data.write(to: url)
        return url
    }

    /// 直链的后缀：取地址路径里的扩展名；认不出来就按 `mp4`（播放器主要吃这个）。
    static func suffix(for url: String) -> String {
        let path = URL(string: url)?.pathExtension ?? ""
        guard (1 ... 5).contains(path.count), path.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return "mp4"
        }
        return path.lowercased()
    }

    /// 不支持的清单（字节范围推不出起点 / 非 AES-128 的加密），各自说清为什么（不猜、不静默产出垃圾）。
    static func refusalReason(_ manifest: HLSManifest) -> String {
        if manifest.hasUnresolvableRange {
            return "这条清单的字节范围缺了起始偏移（不合 RFC 8216 的写法），不敢猜着下"
        }
        return "这条清单用了 SAMPLE-AES 加密（本平台只支持 AES-128），暂不支持下载"
    }

    /// 失败原因：`CatVodError` 自带面向用户的文案（它是 `LocalizedError`），其余用系统描述。
    static func reason(for error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        return error.localizedDescription
    }
}
