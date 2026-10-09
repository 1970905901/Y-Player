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
/// 4. **重试从头下**：续传要对账「已经下到第几片」，而任务里只存了字节数。这一版不假装支持
///    （失败时把半成品删掉），等真有需求再给任务加 `completedSegments`。
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
            return Outcome(task: done, fileURL: result.fileURL)
        } catch {
            return Outcome(
                task: DownloadQueue.applying(failure: Self.reason(for: error), to: running),
                fileURL: nil
            )
        }
    }

    // MARK: - 内部

    private struct FetchDone {
        var received: Int64
        var expected: Int64
        var fileURL: URL
    }

    private func download(
        _ task: DownloadTask,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> FetchDone {
        let first = try await fetch(task.url, task: task)
        let manifest = HLSManifestParser.parse(text: first.text, baseURL: task.url)

        // 不是清单：响应体本身就是内容（直链 mp4 / flv 都走这条），一次写完收工。
        if !manifest.hasContent {
            let fileURL = try write(Data(first.body), as: task, suffix: Self.suffix(for: task.url))
            let size = Int64(first.body.count)
            onProgress?(size, size)
            return FetchDone(received: size, expected: size, fileURL: fileURL)
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

        let fileURL = try makeFile(for: task, suffix: media.hasInitializationSegment ? "mp4" : "ts")
        do {
            return try await writeSegments(media.segments, to: fileURL, task: task, onProgress: onProgress)
        } catch {
            // 半成品删掉：不然重试会接着往一个「少一段」的文件后面写。
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
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
    private struct Written {
        var received: Int64
        var expected: Int64
        var fileURL: URL
    }

    private func fetch(_ url: String, task: DownloadTask) async throws -> Fetch {
        // `URL(string:)` 对任意文本都可能返回非 nil，必须自己查 scheme/host（M06c 踩过一次）。
        guard let target = URL(string: url), target.scheme != nil, target.host != nil else {
            throw CatVodError.parseFailed(
                flag: task.episode,
                reason: "下载地址无法构造 URL：\(url.prefix(120))"
            )
        }
        let request = HTTPRequest(url: target, method: .get, headers: task.headers)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: url,
                reason: "下载「\(task.episode)」返回非 2xx"
            )
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

    /// 逐片下载并追加写。
    ///
    /// 一次打开文件、追加到底：每片都开关一次文件，在几百片的长剧集上会多出几百次系统调用。
    private func writeSegments(
        _ segments: [String],
        to fileURL: URL,
        task: DownloadTask,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Written {
        var received: Int64 = 0
        var expected: Int64 = 0
        var expectedKnown = true
        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            for segment in segments {
                let piece = try await fetch(segment, task: task)
                try handle.write(contentsOf: piece.body)
                received += Int64(piece.body.count)
                if let length = piece.contentLength {
                    expected += length
                } else {
                    expectedKnown = false
                }
                onProgress?(received, expectedKnown ? expected : 0)
            }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return Written(received: received, expected: expectedKnown ? expected : 0, fileURL: fileURL)
    }

    /// 建一个空文件并返回位置。
    ///
    /// 文件名里带上**站点 key**：不同站点可能有同名同集的剧，不带就会互相覆盖
    /// （`fileNameBase` 只由片名 / 集名 / 线路拼成）。
    private func makeFile(for task: DownloadTask, suffix: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = DownloadTask.sanitized("\(task.fileNameBase) · \(task.siteKey)")
        let url = directory.appendingPathComponent(base).appendingPathExtension(suffix)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
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

    /// 不支持的两类清单，各自说清为什么（不猜、不静默产出垃圾）。
    static func refusalReason(_ manifest: HLSManifest) -> String {
        if manifest.isEncrypted {
            return "这条是加密清单（AES-128），本平台暂不支持下载"
        }
        return "这条清单按字节范围取片段（#EXT-X-BYTERANGE），本平台暂不支持下载"
    }

    /// 失败原因：`CatVodError` 自带面向用户的文案（它是 `LocalizedError`），其余用系统描述。
    static func reason(for error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        return error.localizedDescription
    }
}
