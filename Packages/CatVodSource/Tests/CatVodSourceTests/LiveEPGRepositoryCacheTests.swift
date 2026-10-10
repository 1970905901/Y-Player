import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 带落盘缓存的整源节目单加载（M07d7）：新鲜的缓存不发请求、过期重下、失败时旧缓存兜底。
@Suite("EPG 加载：落盘缓存")
struct LiveEPGRepositoryCacheTests {
    /// 同一份 XML 的 gzip 版本（与 `LiveEPGRepositoryTests` 是同一个夹具，`Tools/out/make_epg_fixture.py` 生成）。
    private let gzipXML = """
    H4sIAAAAAAACCl2QsU7DMBCG9zzF6VYUYhcJimS7Q6U+QWG3EpNacuzIOUUtG1vHCiF4CiT28joUeAuStKpavN19
    d7++s5gsKwetiY0NXiK/ZAjG56GwvpR4N5+lY5yoRFALpfEmagoxtf4hpF5XRuKqdnplIqoEQOQL7b1xYAuJeU4t
    H9odKGzTzw07ajqd36ccvrefX5u1yM5Yn5IdYoaijqGMuqoMNKQjSRyx0TVn7Ibfsu7BBRuzTrmhUJ+yqxN2iPun
    RJacAaf7Mx8XqHavH79v25+nl93zu8gGurc5GnS/kFGrkj/o8XlRMwEAAA==
    """

    private func makeDirectory(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yplayer-epg-repository-tests")
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func xml(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="cctv1"><display-name>CCTV-1 综合</display-name></channel>
          <programme start="20261007190000 +0800" stop="20261007193000 +0800" channel="cctv1"><title>\(title)</title></programme>
        </tv>
        """
    }

    private func makeSource(epg: String = "epg/cctv.xml") throws -> LiveSource {
        let json = #"{"name":"演示直播","url":"https://live.example.com/list.m3u8","timeZone":"Asia/Shanghai","ua":"UA-live","epg":"\#(epg)"}"#
        return try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    private func makeCache(_ name: String) throws -> LiveEPGFileCache {
        LiveEPGFileCache(directory: try makeDirectory(name))
    }

    @Test("冷启动：新鲜缓存不发请求，直接用 —— 存的是原样 gz 字节（不是解压后的几十 MB）")
    func freshCacheSkipsNetwork() async throws {
        let cache = try makeCache("fresh")
        let gz = try #require(Data(base64Encoded: gzipXML, options: .ignoreUnknownCharacters))
        let transport = ScriptedEPGRecorder([.ok(gz)])
        let repository = LiveEPGRepository(transport: transport)
        let source = try makeSource(epg: "epg/cctv.xml.gz")
        let key = "https://live.example.com/epg/cctv.xml.gz"

        let first = try await repository.load(source, fileURLs: ["epg/cctv.xml.gz"], cache: cache)
        #expect(first.guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "新闻联播")
        #expect(first.refreshFailure == nil)

        // 第二次（进程重启的等价物）：缓存还新 → 一个请求都不发。
        let second = try await repository.load(source, fileURLs: ["epg/cctv.xml.gz"], cache: cache)
        #expect(second.guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "新闻联播")
        #expect(await transport.requestCount() == 1)

        // 落盘的是 gz 原样字节；数据时刻取缓存那份的时间（不是 now）——界面据此判「够不够新」。
        let stored = try #require(cache.read(key))
        #expect(GZipDecoder.looksLikeGzip(stored.data))
        #expect(second.freshness <= Date())
    }

    @Test("超过 6 小时：重下并覆盖缓存（新一轮内容生效）")
    func staleCacheRefetches() async throws {
        let cache = try makeCache("stale")
        let transport = ScriptedEPGRecorder([
            .ok(Data(xml(title: "旧节目").utf8)),
            .ok(Data(xml(title: "新节目").utf8)),
        ])
        let repository = LiveEPGRepository(transport: transport)
        let source = try makeSource()
        let key = "https://live.example.com/epg/cctv.xml"

        let first = try await repository.load(source, fileURLs: ["epg/cctv.xml"], cache: cache)
        #expect(first.guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "旧节目")

        let stale = Date().addingTimeInterval(7 * 60 * 60)
        let second = try await repository.load(source, fileURLs: ["epg/cctv.xml"], cache: cache, now: stale)
        #expect(second.guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "新节目")
        #expect(second.refreshFailure == nil)
        #expect(await transport.requestCount() == 2)

        // 缓存被覆盖成新内容。
        let stored = try #require(cache.read(key))
        #expect(String(decoding: stored.data, as: UTF8.self).contains("新节目"))
    }

    @Test("刷新失败：旧缓存顶上，原因如实报（refreshFailure）—— 不是「暂无节目」")
    func failedRefreshFallsBackToCache() async throws {
        let cache = try makeCache("fallback")
        let transport = ScriptedEPGRecorder([
            .ok(Data(xml(title: "旧但能用").utf8)),
            .fail(500),
        ])
        let repository = LiveEPGRepository(transport: transport)
        let source = try makeSource()

        _ = try await repository.load(source, fileURLs: ["epg/cctv.xml"], cache: cache)
        let stale = Date().addingTimeInterval(7 * 60 * 60)
        let second = try await repository.load(source, fileURLs: ["epg/cctv.xml"], cache: cache, now: stale)

        #expect(second.guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "旧但能用")
        #expect(second.refreshFailure != nil)
        #expect(await transport.requestCount() == 2)
    }

    @Test("没有缓存又没有网络：如实抛错（保持原来的语义）")
    func failureWithoutCacheThrows() async throws {
        let cache = try makeCache("no-cache")
        let transport = ScriptedEPGRecorder([.fail(500)])
        let source = try makeSource()
        do {
            _ = try await LiveEPGRepository(transport: transport)
                .load(source, fileURLs: ["epg/cctv.xml"], cache: cache)
            Issue.record("没有缓存时失败应当抛错")
        } catch let error as CatVodError {
            guard case .network = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
    }

    @Test("force：缓存再新也重下（换地址 / 手动作废时走这条）")
    func forceRefetches() async throws {
        let cache = try makeCache("force")
        let transport = ScriptedEPGRecorder([
            .ok(Data(xml(title: "旧节目").utf8)),
            .ok(Data(xml(title: "新节目").utf8)),
        ])
        let repository = LiveEPGRepository(transport: transport)
        let source = try makeSource()

        _ = try await repository.load(source, fileURLs: ["epg/cctv.xml"], cache: cache)
        let second = try await repository.load(source, fileURLs: ["epg/cctv.xml"], cache: cache, force: true)
        #expect(second.guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "新节目")
        #expect(await transport.requestCount() == 2)
    }

    @Test("缓存坏了（不是 XMLTV）：当没有、照常联网 —— 不拿半份节目单充数")
    func brokenCacheFallsThroughToNetwork() async throws {
        let cache = try makeCache("broken")
        cache.store(Data("<html>nope</html>".utf8), for: "https://live.example.com/epg/cctv.xml")
        let transport = ScriptedEPGRecorder([.ok(Data(xml(title: "新闻联播").utf8))])
        let source = try makeSource()

        let result = try await LiveEPGRepository(transport: transport)
            .load(source, fileURLs: ["epg/cctv.xml"], cache: cache)
        #expect(result.guide.schedule(key: "cctv1", date: "2026-10-07")?.programs.first?.title == "新闻联播")
        #expect(await transport.requestCount() == 1)
    }
}

/// 按脚本回响应的假传输：缓存用例要看「第一次成功、第二次失败」这种时序，还要数请求次数。
private actor ScriptedEPGRecorder: HTTPTransport {
    enum Step {
        case ok(Data)
        case fail(Int)
    }

    private var steps: [Step]
    private(set) var requests: [HTTPRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else {
            throw CatVodError.network(status: 404, url: request.url.absoluteString, reason: "脚本用完了")
        }
        switch steps.removeFirst() {
        case let .ok(data):
            return HTTPResponse(status: 200, body: data)
        case let .fail(status):
            return HTTPResponse(status: status, body: Data("<html>oops</html>".utf8))
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}
