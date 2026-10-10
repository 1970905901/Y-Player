import CatVodCore
import CatVodNet
import Foundation

// 直链的流式落盘与续下（M25P2）：从 `DownloadRunner.swift` 拆出来 —— 这一块加进去会让
// 原类型体顶破 SwiftLint 的 `type_body_length` 上限；扩展不计入原类型体（与
// `VodDetailView+TMDB.swift` 同一套做法）。
//
// 这些成员因此**不能写 `private`**（private 是文件级，跨文件看不见）：主文件里的
// `FetchDone` / `PartialStop` / `fileURL(for:suffix:)` / `fileSize(of:)` / `contentLength(_:)` /
// `suffix(for:)` / `write(_:as:suffix:)` / `downloadManifest(_:task:onProgress:)`
// 随本次拆分从 private 放宽到 internal，各自带着一行说明。
extension DownloadRunner {
    /// 流式传输（M25P2）：先看开头 —— `#EXTM3U` = 清单，否则 = 直链文件。
    ///
    /// 直链这一条是真的流式：边收边写盘、边报进度；半途失败 / 暂停留下的字节就是下次
    /// 续下的账目（带 `Range` 接着下，见 ``matchesResume(offset:total:headers:)``）。
    // （internal：`DownloadRunner.swift` 的 `download()` 要调它，不能是 private。）
    func downloadStreaming(
        _ task: DownloadTask,
        streaming: HTTPStreamingTransport,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> FetchDone {
        let target = try fileURL(for: task, suffix: Self.suffix(for: task.url))
        // 能续就续：账目齐（字节 + 总长）且文件里正好有那么多字节。
        var offset: Int64 = 0
        var knownTotal: Int64 = 0
        if task.receivedBytes > 0, task.expectedBytes > 0, Self.fileSize(of: target) == task.receivedBytes {
            offset = task.receivedBytes
            knownTotal = task.expectedBytes
        }
        var restarted = false
        while true {
            let piece = try await openPiece(task.url, task: task, from: offset > 0 ? offset : nil, streaming: streaming)
            if offset > 0, piece.status == 206,
               Self.matchesResume(offset: offset, total: knownTotal, headers: piece.headers)
            {
                return try await writePiece(
                    piece, cursor: ChunkCursor(stream: piece.chunks), to: target,
                    mode: .append(from: offset), declaredTotal: knownTotal,
                    task: task, onProgress: onProgress
                )
            }
            // 416 / 带着 Range 却回了个对不上的 206 / 其它非 200：远端换过或不让续 ——
            // 清掉半成品、整份重下一次（只重来一次，再不对就说清楚）。
            if piece.status != 200 {
                piece.cancel()
                guard !restarted, offset > 0 else {
                    throw CatVodError.network(
                        status: piece.status,
                        url: task.url,
                        reason: "下载「\(task.episode)」返回非 2xx"
                    )
                }
                restarted = true
                offset = 0
                continue
            }
            // 200：从头看 —— 先收开头，判断是清单还是文件。
            let cursor = ChunkCursor(stream: piece.chunks)
            if let head = try await cursor.peek(), Self.looksLikeManifest(head) {
                // 清单（本来就不大）：把剩下的收完，走 HLS 那套。
                var text = Data()
                while let chunk = try await cursor.next() {
                    text.append(chunk)
                }
                // 同上：取消时 `next()` 回 nil、清单只收了一半 —— 不拦的话会被当成
                // 「说好是清单却没有片段」，把半份清单写成一个假文件（还报成功）。
                try Task.checkCancellation()
                let manifest = HLSManifestParser.parse(text: String(decoding: text, as: UTF8.self), baseURL: task.url)
                if manifest.hasContent {
                    return try await downloadManifest(manifest, task: task, onProgress: onProgress)
                }
                // 说好是清单却没有片段（服务器抽风 / 认错了）：当文件写下去，别把字节丢了。
                let fileURL = try write(text, as: task, suffix: Self.suffix(for: task.url))
                let size = Int64(text.count)
                onProgress?(DownloadProgress(receivedBytes: size, expectedBytes: size, completedSegments: 0, totalSegments: 0))
                return FetchDone(received: size, expected: size, fileURL: fileURL, completedSegments: 0, fingerprint: "")
            }
            return try await writePiece(
                piece, cursor: cursor, to: target, mode: .fresh,
                declaredTotal: Self.contentLength(piece.headers),
                task: task, onProgress: onProgress
            )
        }
    }

    // MARK: - 直链流式落盘（M25P2）

    /// 落盘方式：`fresh` = 从 0 写（清掉旧文件），`append` = 从账目那一位接着写。
    private enum PieceMode {
        case fresh
        case append(from: Int64)
    }

    /// 「已经读出来的开头 + 剩下的块」—— 一个可以继续 `next()` 的游标（M25P2）。
    ///
    /// 判定「是清单还是文件」得先读开头，读过的块不能丢：`peek` 先存住，写盘时再吐回来。
    private final class ChunkCursor {
        private var pending: [Data]
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator

        init(stream: AsyncThrowingStream<Data, Error>) {
            pending = []
            iterator = stream.makeAsyncIterator()
        }

        /// 先看一眼开头（不消费：之后 `next()` 还会先把它吐回来）。
        func peek() async throws -> Data? {
            guard let chunk = try await next() else {
                return nil
            }
            pending.append(chunk)
            return chunk
        }

        /// 下一块（`peek` 存下的会先回来）。
        func next() async throws -> Data? {
            if !pending.isEmpty {
                return pending.removeFirst()
            }
            return try await iterator.next()
        }
    }

    /// 取一段直链：带 `Range: bytes=N-`（续下）或不带；有流式传输就走流式。
    private func openPiece(
        _ url: String,
        task: DownloadTask,
        from offset: Int64?,
        streaming: HTTPStreamingTransport
    ) async throws -> HTTPStream {
        guard let target = URL(string: url), target.scheme != nil, target.host != nil else {
            throw CatVodError.parseFailed(
                flag: task.episode,
                reason: "下载地址无法构造 URL：\(url.prefix(120))"
            )
        }
        var headers = task.headers
        if let offset {
            headers["Range"] = "bytes=\(offset)-"
        }
        return try await streaming.stream(HTTPRequest(url: target, method: .get, headers: headers))
    }

    /// 把块游标里的字节写进文件（M25P2）：边收边写、边报进度；失败 / 取消**不删文件**，
    /// 把「写了多少」交给 ``PartialStop``（下次续下的账目）。
    private func writePiece(
        _ piece: HTTPStream,
        cursor: ChunkCursor,
        to target: URL,
        mode: PieceMode,
        declaredTotal: Int64?,
        task: DownloadTask,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> FetchDone {
        var received: Int64
        let handle: FileHandle
        switch mode {
        case .fresh:
            try? FileManager.default.removeItem(at: target)
            _ = FileManager.default.createFile(atPath: target.path, contents: nil)
            handle = try FileHandle(forWritingTo: target)
            received = 0
        case let .append(from: offset):
            handle = try FileHandle(forWritingTo: target)
            // 账目说写到这里：多出来的尾巴（上次写了一半）截掉，写指针摆到末尾。
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seekToEnd()
            received = offset
        }
        var reported = received
        do {
            try await withTaskCancellationHandler {
                while let chunk = try await cursor.next() {
                    try Task.checkCancellation()
                    guard !chunk.isEmpty else {
                        continue
                    }
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                    if received - reported >= Self.progressStep {
                        reported = received
                        onProgress?(DownloadProgress(
                            receivedBytes: received,
                            expectedBytes: declaredTotal ?? 0,
                            completedSegments: 0,
                            totalSegments: 0
                        ))
                    }
                }
                // 取消时迭代器会**直接结束流**（`next()` 回 nil，不抛错）—— 循环因此「正常」退出，
                // 接着走下面的对账就会把「取消」当成「字节数对不上」报出去，账目全丢（M25P2 首验踩过）。
                // 补这一下：取消就是取消，半途的账目照抛。
                try Task.checkCancellation()
            } onCancel: {
                // 暂停：把底层连接关掉（流以错误收尾），已经写下的字节留在文件里。
                piece.cancel()
            }
        } catch {
            try? handle.close()
            throw PartialStop(
                completedSegments: 0,
                receivedBytes: received,
                expectedBytes: declaredTotal ?? 0,
                fingerprint: "",
                underlying: error
            )
        }
        try handle.close()
        // 收完再对一遍账：说好的整段必须到齐（206 续下 / 有 Content-Length 的整份）。
        if let declaredTotal, received != declaredTotal {
            throw CatVodError.parseFailed(
                flag: task.episode,
                reason: "字节数对不上：应有 \(declaredTotal) 字节，只收到 \(received)"
            )
        }
        onProgress?(DownloadProgress(
            receivedBytes: received,
            expectedBytes: declaredTotal ?? received,
            completedSegments: 0,
            totalSegments: 0
        ))
        return FetchDone(
            received: received,
            expected: declaredTotal ?? received,
            fileURL: target,
            completedSegments: 0,
            fingerprint: ""
        )
    }

    /// 续下的三个硬检查（M25P2）：`Content-Range` 的**起点**与**总长**都得与账目对上
    /// （状态是不是 206 由调用方先看过）。对不上就整份重下 —— 远端换过文件时总长大概率
    /// 对不上，拿旧前缀硬拼会拼出一个看不出来的错文件。
    static func matchesResume(offset: Int64, total: Int64, headers: [String: String]) -> Bool {
        guard let range = contentRange(headers) else {
            return false
        }
        return range.start == offset && range.total == total
    }

    /// `Content-Range: bytes 100-199/200` → `(start: 100, total: 200)`；认不出来给 nil。
    static func contentRange(_ headers: [String: String]) -> (start: Int64, total: Int64)? {
        for (key, value) in headers where key.lowercased() == "content-range" {
            let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 2, parts[0].lowercased() == "bytes" else {
                continue
            }
            let halves = parts[1].split(separator: "/")
            guard halves.count == 2, halves[1] != "*",
                  let start = halves[0].split(separator: "-").first.flatMap({ Int64($0) }),
                  let total = Int64(halves[1])
            else {
                continue
            }
            return (start, total)
        }
        return nil
    }

    /// 开头像不像 HLS 清单（RFC 8216：清单必须以 `#EXTM3U` 开头；容忍 BOM 与空行）。
    static func looksLikeManifest(_ head: Data) -> Bool {
        let text = String(decoding: head.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("#EXTM3U")
    }

    /// 流式落盘的进度上报步长（M25P2）：每写这么多字节报一次。每块（64KB）都报的话，
    /// 回调要跨线程蹦一次，GB 级文件会蹦几万次。
    static let progressStep: Int64 = 1_048_576
}
