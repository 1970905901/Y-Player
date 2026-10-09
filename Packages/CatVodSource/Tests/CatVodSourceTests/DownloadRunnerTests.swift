import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 按地址回内容的假传输：记录每次请求，用来断言「每一片都带了同一套 header」。
private actor StubTransport: HTTPTransport {
    private let responses: [String: HTTPResponse]
    private var requests: [HTTPRequest] = []

    init(_ responses: [String: HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return responses[request.url.absoluteString] ?? HTTPResponse(status: 404)
    }

    func requestedURLs() -> [String] {
        requests.map(\.url.absoluteString)
    }

    func headers(for url: String) -> [[String: String]] {
        requests.filter { $0.url.absoluteString == url }.map(\.headers)
    }
}

@Suite("下载执行器：直链 / HLS 拼接 / 失败回退")
struct DownloadRunnerTests {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yplayer-download-tests")

    private func makeTask(_ url: String) -> DownloadTask {
        DownloadTask(
            siteKey: "wogg",
            title: "某剧",
            episode: "第 1 集",
            line: "线路一",
            url: url,
            headers: ["User-Agent": "YPlayer", "Referer": "https://site.example"]
        )
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func playlist(_ body: String) -> HTTPResponse {
        let data = "#EXTM3U\n\(body)".data(using: .utf8) ?? Data()
        return HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/vnd.apple.mpegurl"],
            body: data
        )
    }

    private func segment(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: text.data(using: .utf8) ?? Data())
    }

    @Test("直链（不是清单）：一次取回写成文件，字节数与状态都对")
    func directFile() async throws {
        let directory = try makeDirectory("direct")
        let url = "https://cdn.example/movie.mp4"
        let payload = String(repeating: "A", count: 512)
        let transport = StubTransport([url: HTTPResponse(
            status: 200,
            headers: ["Content-Length": "512"],
            body: payload.data(using: .utf8) ?? Data()
        )])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(url))
        #expect(outcome.task.status == .finished)
        #expect(outcome.task.receivedBytes == 512)
        #expect(outcome.task.expectedBytes == 512)
        #expect(outcome.task.progress == 1)

        let fileURL = try #require(outcome.fileURL)
        #expect(fileURL.pathExtension == "mp4")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == payload)
        #expect(await transport.requestedURLs() == [url])
    }

    @Test("HLS：清单 + 分片，按顺序追加拼成一个 .ts，每片都带同一套 header")
    func hlsConcatenatesSegments() async throws {
        let directory = try makeDirectory("hls")
        let index = "https://cdn.example/v/index.m3u8"
        let transport = StubTransport([
            index: playlist("#EXTINF:4,\nseg-1.ts\n#EXTINF:4,\nseg-2.ts\n#EXT-X-ENDLIST"),
            "https://cdn.example/v/seg-1.ts": segment("AAA"),
            "https://cdn.example/v/seg-2.ts": segment("BBBB"),
        ])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(index))
        #expect(outcome.task.status == .finished)
        #expect(outcome.task.receivedBytes == 7)

        let fileURL = try #require(outcome.fileURL)
        #expect(fileURL.pathExtension == "ts")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "AAABBBB")
        #expect(await transport.requestedURLs() == [
            index,
            "https://cdn.example/v/seg-1.ts",
            "https://cdn.example/v/seg-2.ts",
        ])
        // 鉴权多半挂在 header 上：漏一片就是 403
        let headers = await transport.headers(for: "https://cdn.example/v/seg-1.ts")
        #expect(headers == [["User-Agent": "YPlayer", "Referer": "https://site.example"]])
    }

    @Test("fMP4（有 init 片）：后缀是 .mp4，且 init 片必须第一个被取")
    func fmp4UsesMP4Suffix() async throws {
        let directory = try makeDirectory("fmp4")
        let index = "https://cdn.example/v/index.m3u8"
        let transport = StubTransport([
            index: playlist("#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\nseg-1.m4s"),
            "https://cdn.example/v/init.mp4": segment("INIT"),
            "https://cdn.example/v/seg-1.m4s": segment("DATA"),
        ])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(index))
        let fileURL = try #require(outcome.fileURL)
        #expect(fileURL.pathExtension == "mp4")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "INITDATA")
        #expect(await transport.requestedURLs() == [
            index,
            "https://cdn.example/v/init.mp4",
            "https://cdn.example/v/seg-1.m4s",
        ])
    }

    @Test("主清单：跟随带宽最高的变体")
    func followsBestVariant() async throws {
        let directory = try makeDirectory("master")
        let index = "https://cdn.example/v/index.m3u8"
        let transport = StubTransport([
            index: playlist("""
            #EXT-X-STREAM-INF:BANDWIDTH=800000
            low.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2400000
            high.m3u8
            """),
            "https://cdn.example/v/high.m3u8": playlist("#EXTINF:4,\nseg.ts"),
            "https://cdn.example/v/seg.ts": segment("HI"),
        ])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(index))
        #expect(outcome.task.status == .finished)
        #expect(await transport.requestedURLs() == [
            index,
            "https://cdn.example/v/high.m3u8",
            "https://cdn.example/v/seg.ts",
        ])
    }

    @Test("加密清单：如实拒绝（按重试规则先回排队），不留下半成品")
    func refusesEncrypted() async throws {
        let directory = try makeDirectory("encrypted")
        let index = "https://cdn.example/v/index.m3u8"
        let transport = StubTransport([
            index: playlist("#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nseg.ts"),
        ])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(index))
        #expect(outcome.fileURL == nil)
        #expect(outcome.task.status == .waiting)
        #expect(outcome.task.failureReason.contains("加密"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("某片挂了：回退排队 + 半成品删掉（重试要从头下，不能往少一段的文件后面写）")
    func removesPartialFileOnFailure() async throws {
        let directory = try makeDirectory("failure")
        let index = "https://cdn.example/v/index.m3u8"
        let transport = StubTransport([
            index: playlist("#EXTINF:4,\nseg-1.ts\n#EXTINF:4,\nseg-missing.ts"),
            "https://cdn.example/v/seg-1.ts": segment("AAA"),
        ])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(index))
        #expect(outcome.fileURL == nil)
        #expect(outcome.task.status == .waiting)
        #expect(outcome.task.retryCount == 1)
        #expect(!outcome.task.failureReason.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("文件名带上站点 key：两个站点的同名同集不会互相覆盖")
    func fileNameIncludesSiteKey() async throws {
        let directory = try makeDirectory("naming")
        let url = "https://cdn.example/movie.mp4"
        let transport = StubTransport([url: HTTPResponse(status: 200, body: Data([0x1]))])
        let runner = DownloadRunner(transport: transport, directory: directory)

        let outcome = await runner.run(makeTask(url))
        let fileURL = try #require(outcome.fileURL)
        #expect(fileURL.lastPathComponent.contains("wogg"))
        #expect(fileURL.lastPathComponent.contains("某剧"))
    }
}
