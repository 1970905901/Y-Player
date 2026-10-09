import CatVodCore
import CatVodNet
@testable import CatVodUI
import Foundation
import Testing

/// 按地址回内容的假传输（与 `DownloadRunnerTests` 同一思路：测试目标之间不共享私有桩）。
private actor WiringTransport: HTTPTransport {
    private let responses: [String: HTTPResponse]

    init(_ responses: [String: HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        responses[request.url.absoluteString] ?? HTTPResponse(status: 404)
    }
}

@Suite("离线下载接线：入队 / 驱动 / 删除")
struct DownloadWiringTests {
    private func direct(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Length": "\(text.utf8.count)"], body: Data(text.utf8))
    }

    private func playlist(_ text: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/vnd.apple.mpegurl"],
            body: Data(text.utf8)
        )
    }

    @Test("入队：落库 + 镜像同步；空地址的集不入队；重复的集不重复加")
    func enqueueDownloads() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        let added = await fixture.model.enqueueDownloads(
            [
                DownloadRequest(episode: "第 1 集", line: "线路一", url: "https://cdn.example/1.mp4"),
                DownloadRequest(episode: "第 2 集", line: "线路一", url: "https://cdn.example/2.mp4"),
                DownloadRequest(episode: "第 3 集", line: "线路一", url: "   "),
            ],
            siteKey: "a",
            title: "某剧"
        )
        #expect(added.map(\.episode) == ["第 1 集", "第 2 集"])
        #expect(fixture.model.downloadTasks.map(\.episode) == ["第 1 集", "第 2 集"])
        #expect(await fixture.model.downloadStore.count() == 2)

        let again = await fixture.model.enqueueDownloads(
            [DownloadRequest(episode: "第 1 集", line: "线路一", url: "https://cdn.example/1.mp4")],
            siteKey: "a",
            title: "某剧"
        )
        #expect(again.isEmpty)
        #expect(await fixture.model.downloadStore.count() == 2)
    }

    @Test("驱动：跑完一条直链，状态与文件都到位")
    func runsQueue() async throws {
        let url = "https://cdn.example/1.mp4"
        let fixture = try AppModelFixture(downloadTransport: WiringTransport([url: direct("hello")]))
        defer { fixture.tearDown() }
        await fixture.load()

        await fixture.model.enqueueDownloads(
            [DownloadRequest(episode: "第 1 集", line: "线路一", url: url)],
            siteKey: "a",
            title: "某剧"
        )
        #expect(await fixture.model.runDownloadQueue() == 1)

        let task = try #require(fixture.model.downloadTasks.first)
        #expect(task.status == DownloadTask.Status.finished)
        #expect(task.receivedBytes == 5)
        #expect(!fixture.model.isDownloading)

        let directory = AppModelFixture.downloadDirectory(in: fixture.directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test("暂停 / 继续 / 删除：删除要连文件一起删")
    func pauseResumeRemove() async throws {
        let url = "https://cdn.example/1.mp4"
        let fixture = try AppModelFixture(downloadTransport: WiringTransport([url: direct("hello")]))
        defer { fixture.tearDown() }
        await fixture.load()

        let added = await fixture.model.enqueueDownloads(
            [DownloadRequest(episode: "第 1 集", line: "线路一", url: url)],
            siteKey: "a",
            title: "某剧"
        )
        let id = try #require(added.first?.id)

        await fixture.model.pauseDownload(id: id)
        #expect(fixture.model.downloadTasks.first?.status == DownloadTask.Status.paused)
        // 暂停的不会被驱动启动（用户意愿，不该被「顺手」启动）
        #expect(await fixture.model.runDownloadQueue() == 0)

        await fixture.model.resumeDownload(id: id)
        #expect(fixture.model.downloadTasks.first?.status == DownloadTask.Status.waiting)
        #expect(await fixture.model.runDownloadQueue() == 1)

        let directory = AppModelFixture.downloadDirectory(in: fixture.directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)

        await fixture.model.removeDownload(id: id)
        #expect(fixture.model.downloadTasks.isEmpty)
        #expect(await fixture.model.downloadStore.count() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("重开模型：任务还在（库是唯一来源）")
    func survivesReopen() async throws {
        let url = "https://cdn.example/1.mp4"
        let fixture = try AppModelFixture(downloadTransport: WiringTransport([url: direct("hello")]))
        defer { fixture.tearDown() }
        await fixture.load()

        await fixture.model.enqueueDownloads(
            [DownloadRequest(episode: "第 1 集", line: "线路一", url: url)],
            siteKey: "a",
            title: "某剧"
        )
        _ = await fixture.model.runDownloadQueue()

        let reopened = try fixture.reopenedModel()
        await reopened.synchronizeDownloads()
        #expect(reopened.downloadTasks.count == 1)
        #expect(reopened.downloadTasks.first?.status == DownloadTask.Status.finished)
    }

    @Test("本地接管：下好的集直接播本地文件；排队中 / 没下载都不接管")
    func localFileTakesOver() async throws {
        let url = "https://cdn.example/1.mp4"
        let fixture = try AppModelFixture(downloadTransport: WiringTransport([url: direct("hello")]))
        defer { fixture.tearDown() }
        await fixture.load()

        let resource = MediaResource(url: url, headers: ["Referer": "https://site.example"])
        // 还没入队：不接管，原样给回远地址
        #expect(fixture.model.localDownloadedFile(forRemoteURL: url) == nil)
        #expect(fixture.model.proxiedMediaResource(resource).url == url)

        await fixture.model.enqueueDownloads(
            [DownloadRequest(episode: "第 1 集", line: "线路一", url: url)],
            siteKey: "a",
            title: "某剧"
        )
        // 排队中也不接管：半截文件播不了
        #expect(fixture.model.localDownloadedFile(forRemoteURL: url) == nil)

        _ = await fixture.model.runDownloadQueue()
        let local = try #require(fixture.model.localDownloadedFile(forRemoteURL: url))
        #expect(local.isFileURL)

        // 接管之后：地址换成文件、header 清空（本地文件不该再带鉴权头）
        let swapped = fixture.model.proxiedMediaResource(resource)
        #expect(swapped.url == local.absoluteString)
        #expect(swapped.headers.isEmpty)
    }

    @Test("接管的文件也删得掉：删除后不再接管")
    func removingFileRestoresRemote() async throws {
        let url = "https://cdn.example/1.mp4"
        let fixture = try AppModelFixture(downloadTransport: WiringTransport([url: direct("hello")]))
        defer { fixture.tearDown() }
        await fixture.load()

        let added = await fixture.model.enqueueDownloads(
            [DownloadRequest(episode: "第 1 集", line: "线路一", url: url)],
            siteKey: "a",
            title: "某剧"
        )
        let id = try #require(added.first?.id)
        _ = await fixture.model.runDownloadQueue()
        #expect(fixture.model.localDownloadedFile(forRemoteURL: url) != nil)

        await fixture.model.removeDownload(id: id)
        #expect(fixture.model.localDownloadedFile(forRemoteURL: url) == nil)
    }

    @Test("HLS：清单 + 分片拼成一个 .ts 落地")
    func runsHLS() async throws {
        let index = "https://cdn.example/v/index.m3u8"
        let fixture = try AppModelFixture(downloadTransport: WiringTransport([
            index: playlist("#EXTM3U\n#EXTINF:4,\nseg-1.ts\n#EXTINF:4,\nseg-2.ts"),
            "https://cdn.example/v/seg-1.ts": HTTPResponse(status: 200, body: Data("AAA".utf8)),
            "https://cdn.example/v/seg-2.ts": HTTPResponse(status: 200, body: Data("BBBB".utf8)),
        ]))
        defer { fixture.tearDown() }
        await fixture.load()

        await fixture.model.enqueueDownloads(
            [DownloadRequest(episode: "第 1 集", line: "线路一", url: index)],
            siteKey: "a",
            title: "某剧"
        )
        #expect(await fixture.model.runDownloadQueue() == 1)

        let directory = AppModelFixture.downloadDirectory(in: fixture.directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        let name = try #require(files.first)
        #expect(name.hasSuffix(".ts"))
        let written = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        #expect(written == "AAABBBB")
    }
}
