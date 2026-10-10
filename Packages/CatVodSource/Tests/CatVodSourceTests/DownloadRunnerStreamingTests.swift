@testable import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

// 直链的流式落盘与 Range 续下（M25P2）的用例。单独一个文件而不是并进
// `DownloadRunnerTests.swift`：那边再加就顶破 SwiftLint 的 `file_length` 800 上限，
// 而流式桩只服务这一套。共用的小工具在那边的文件级 —— `sliced` / `makeTask` /
// `writePartial` / `waitUntil` / `ProgressRecorder` / `makeDownloadTestDirectory`。

/// 流式假传输（M25P2）：按地址回「整份字节 + 怎么分块 + 什么时候断线」；带 `Range` 的请求
/// 像真服务器一样切片回 206。块之间可以加延迟 —— 「暂停在下到一半」得有时间按下去。
private actor StreamingStubTransport: HTTPStreamingTransport {
    struct Piece {
        var body: Data
        /// 每块多少字节。
        var chunkSize: Int = 8
        /// 块之间的间隔（演慢源）。
        var chunkDelayNanos: UInt64 = 0
        /// 吐完这么多块之后断线（nil = 收完）。
        var failAfterChunks: Int?
        /// 不认 `Range`：整份回 200（演不支持续下的远端）。
        var ignoresRange: Bool = false
    }

    private var pieces: [String: Piece]
    private var requests: [HTTPRequest] = []

    init(_ pieces: [String: Piece]) {
        self.pieces = pieces
    }

    /// 换一份（演「修好了 / 换源了」之后的第二次取）。
    func setPiece(_ piece: Piece, for url: String) {
        pieces[url] = piece
    }

    /// 非流式的普通取回（协议要求；HLS 清单里的分片走它）。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard let piece = pieces[request.url.absoluteString] else {
            return HTTPResponse(status: 404)
        }
        let full = HTTPResponse(status: 200, headers: ["Content-Length": "\(piece.body.count)"], body: piece.body)
        return piece.ignoresRange ? full : sliced(full, for: request.headers["Range"])
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        requests.append(request)
        guard let piece = pieces[request.url.absoluteString] else {
            return HTTPStream(status: 404, chunks: AsyncThrowingStream { $0.finish() }, cancel: { })
        }
        let full = HTTPResponse(status: 200, headers: ["Content-Length": "\(piece.body.count)"], body: piece.body)
        let response = piece.ignoresRange ? full : sliced(full, for: request.headers["Range"])
        guard response.isSuccess else {
            return HTTPStream(
                status: response.status,
                headers: response.headers,
                chunks: AsyncThrowingStream { $0.finish() },
                cancel: { }
            )
        }
        let box = StreamCancelBox()
        let body = response.body
        let delay = piece.chunkDelayNanos
        let failAfter = piece.failAfterChunks
        let chunkSize = max(1, piece.chunkSize)
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var offset = 0
                var index = 0
                while offset < body.count {
                    if let failAfter, index >= failAfter {
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                        return
                    }
                    if delay > 0 {
                        do {
                            try await Task.sleep(nanoseconds: delay)
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    let end = min(offset + chunkSize, body.count)
                    continuation.yield(body.subdata(in: offset ..< end))
                    offset = end
                    index += 1
                }
                if let failAfter, index >= failAfter {
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                    return
                }
                continuation.finish()
            }
            box.store(task)
            continuation.onTermination = { _ in box.cancel() }
        }
        return HTTPStream(status: response.status, headers: response.headers, chunks: chunks, cancel: { box.cancel() })
    }

    func requestedURLs() -> [String] {
        requests.map(\.url.absoluteString)
    }

    /// 某个地址收到的 `Range` 头（按请求顺序）。
    func rangeHeaders(for url: String) -> [String] {
        requests.filter { $0.url.absoluteString == url }.compactMap { $0.headers["Range"] }
    }
}

/// 流式桩的取消把手：`cancel` 回调从消费者的上下文来，得自己上锁。
private final class StreamCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func store(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

@Suite("下载执行器：直链流式与 Range 续下（M25P2）")
struct DownloadRunnerStreamingTests {
    private func makeDirectory(_ name: String) throws -> URL {
        try makeDownloadTestDirectory(name)
    }

    @Test("直链流式：边收边写盘，收完按 Content-Length 对账，进度终点带真总量")
    func streamsDirectFile() async throws {
        let directory = try makeDirectory("stream-direct")
        let url = "https://cdn.example/movie.mp4"
        let payload = Data((0 ..< 32).map { UInt8($0) })
        let transport = StreamingStubTransport([url: .init(body: payload)])
        let runner = DownloadRunner(transport: transport, directory: directory)
        let recorder = ProgressRecorder()

        let outcome = await runner.run(makeTask(url)) { recorder.append($0) }

        #expect(outcome.task.status == .finished)
        #expect(outcome.task.receivedBytes == 32)
        #expect(outcome.task.expectedBytes == 32)
        let fileURL = try #require(outcome.fileURL)
        #expect(fileURL.pathExtension == "mp4")
        #expect(try Data(contentsOf: fileURL) == payload)
        // 头一次取（没有账目）不带 Range
        let ranges = await transport.rangeHeaders(for: url)
        #expect(ranges.isEmpty)
        let reported = recorder.all
        #expect(reported.last?.receivedBytes == 32)
        #expect(reported.last?.expectedBytes == 32)
        let segmentless = reported.allSatisfy { $0.completedSegments == 0 && $0.totalSegments == 0 }
        #expect(segmentless)
    }

    @Test("大直链：没下完就报进度，分母是 Content-Length 的真值（不拿前缀冒充）")
    func reportsMidStreamProgress() async throws {
        let directory = try makeDirectory("stream-progress")
        let url = "https://cdn.example/movie.mp4"
        let size = 2 * 1_048_576
        let payload = Data(repeating: 0x5A, count: size)
        let transport = StreamingStubTransport([url: .init(body: payload, chunkSize: 262_144)])
        let runner = DownloadRunner(transport: transport, directory: directory)
        let recorder = ProgressRecorder()

        let outcome = await runner.run(makeTask(url)) { recorder.append($0) }

        #expect(outcome.task.status == .finished)
        let reported = recorder.all
        // 中途那几次（1MB 步长）就该带着真总量：进度条不用等收完
        let midStream = reported.filter { $0.receivedBytes > 0 && $0.receivedBytes < Int64(size) }
        #expect(!midStream.isEmpty)
        let honestTotals = midStream.allSatisfy { $0.expectedBytes == Int64(size) }
        #expect(honestTotals)
        #expect(reported.last?.receivedBytes == Int64(size))
    }

    @Test("暂停在半途：回「已暂停」、不吃重试额度；半成品与账目都留着（下次接着下）")
    func pauseMidStream() async throws {
        let directory = try makeDirectory("stream-pause")
        let url = "https://cdn.example/movie.mp4"
        let payload = Data(repeating: 0x42, count: 64)
        var piece = StreamingStubTransport.Piece(body: payload)
        piece.chunkDelayNanos = 30_000_000
        let transport = StreamingStubTransport([url: piece])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let handle = Task { await runner.run(makeTask(url)) }
        // 等至少写下一块（8 字节）再按暂停：一份都没写下的话「半成品留着」无从谈起
        let wrote = await waitUntil {
            guard let name = try? FileManager.default.contentsOfDirectory(atPath: directory.path).first else {
                return false
            }
            return (DownloadRunner.fileSize(of: directory.appendingPathComponent(name)) ?? 0) >= 8
        }
        #expect(wrote)
        handle.cancel()
        let outcome = await handle.value

        #expect(outcome.task.status == .paused)
        #expect(outcome.task.retryCount == 0)
        #expect(outcome.task.failureReason.isEmpty)
        #expect(outcome.fileURL == nil)
        // 账目 = 文件里真有的字节数；总量是 Content-Length 的真值（续下不用再猜）
        #expect(outcome.task.receivedBytes >= 8)
        #expect(outcome.task.receivedBytes < 64)
        #expect(outcome.task.expectedBytes == 64)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        let name = try #require(files.first)
        let onDisk = try Data(contentsOf: directory.appendingPathComponent(name))
        #expect(Int64(onDisk.count) == outcome.task.receivedBytes)
    }

    @Test("续下：断线留下 16 字节，重试带 Range 只取剩下的，拼回整份")
    func resumesAfterDropout() async throws {
        let directory = try makeDirectory("stream-resume")
        let url = "https://cdn.example/movie.mp4"
        let payload = Data((0 ..< 32).map { UInt8($0) })
        var piece = StreamingStubTransport.Piece(body: payload)
        // 吐 2 块（16 字节）之后断线
        piece.failAfterChunks = 2
        let transport = StreamingStubTransport([url: piece])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let failed = await runner.run(makeTask(url))
        #expect(failed.task.status == .waiting)
        #expect(failed.task.retryCount == 1)
        #expect(failed.fileURL == nil)
        #expect(failed.task.receivedBytes == 16)
        #expect(failed.task.expectedBytes == 32)

        // 修好之后重试（换一份不带断线的响应）：带 Range 从第 16 字节接着写
        await transport.setPiece(StreamingStubTransport.Piece(body: payload), for: url)
        let resumed = await runner.run(failed.task)

        #expect(resumed.task.status == .finished)
        #expect(resumed.task.receivedBytes == 32)
        let ranges = await transport.rangeHeaders(for: url)
        // 只有第二趟带了 Range：第一趟没有账目，从头下
        #expect(ranges == ["bytes=16-"])
        let fileURL = try #require(resumed.fileURL)
        #expect(try Data(contentsOf: fileURL) == payload)
    }

    @Test("续下对不上（远端总长变了）：整份重下，绝不拿旧前缀硬拼")
    func restartsWhenTotalChanged() async throws {
        let directory = try makeDirectory("stream-total-changed")
        let url = "https://cdn.example/movie.mp4"
        let old = Data((0 ..< 32).map { UInt8($0) })
        let new = Data((0 ..< 40).map { UInt8(($0 * 7) % 256) })
        var piece = StreamingStubTransport.Piece(body: old)
        piece.failAfterChunks = 2
        let transport = StreamingStubTransport([url: piece])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let failed = await runner.run(makeTask(url))
        #expect(failed.task.receivedBytes == 16)
        #expect(failed.task.expectedBytes == 32)

        // 远端换过文件：账目还是 32 字节的老账，Range 回的是 40 字节的新总长
        await transport.setPiece(StreamingStubTransport.Piece(body: new), for: url)
        let restarted = await runner.run(failed.task)

        #expect(restarted.task.status == .finished)
        #expect(restarted.task.receivedBytes == 40)
        let fileURL = try #require(restarted.fileURL)
        #expect(try Data(contentsOf: fileURL) == new)
        let ranges = await transport.rangeHeaders(for: url)
        // 只发过一次 Range（那次对不上）；整份重来那次没带
        #expect(ranges == ["bytes=16-"])
    }

    @Test("远端不认 Range（整份回 200）：账目作废，整份重写 —— 不硬拼")
    func restartsWhenRangeIgnored() async throws {
        let directory = try makeDirectory("stream-range-ignored")
        let url = "https://cdn.example/movie.mp4"
        let payload = Data((0 ..< 32).map { UInt8($0) })
        var piece = StreamingStubTransport.Piece(body: payload)
        piece.failAfterChunks = 2
        let transport = StreamingStubTransport([url: piece])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let failed = await runner.run(makeTask(url))
        #expect(failed.task.receivedBytes == 16)

        // 远端对 Range 视而不见、整份回 200：旧前缀作废，整份重写
        await transport.setPiece(StreamingStubTransport.Piece(body: payload, ignoresRange: true), for: url)
        let resumed = await runner.run(failed.task)

        #expect(resumed.task.status == .finished)
        #expect(resumed.task.receivedBytes == 32)
        let fileURL = try #require(resumed.fileURL)
        #expect(try Data(contentsOf: fileURL) == payload)
        let ranges = await transport.rangeHeaders(for: url)
        #expect(ranges == ["bytes=16-"])
    }

    @Test("流式传输下的 HLS：清单收进内存、分片逐片取（真传输两条协议都过）")
    func streamsManifest() async throws {
        let directory = try makeDirectory("stream-manifest")
        let index = "https://cdn.example/v/index.m3u8"
        let transport = StreamingStubTransport([
            index: .init(body: Data("#EXTM3U\n#EXTINF:4,\nseg-1.ts\n#EXTINF:4,\nseg-2.ts".utf8)),
            "https://cdn.example/v/seg-1.ts": .init(body: Data("AAA".utf8)),
            "https://cdn.example/v/seg-2.ts": .init(body: Data("BBBB".utf8)),
        ])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(index))

        #expect(outcome.task.status == .finished)
        let fileURL = try #require(outcome.fileURL)
        #expect(fileURL.pathExtension == "ts")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "AAABBBB")
        let requested = await transport.requestedURLs()
        #expect(requested == [index, "https://cdn.example/v/seg-1.ts", "https://cdn.example/v/seg-2.ts"])
    }
}
