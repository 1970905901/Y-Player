import CatVodCore
import CatVodNet
@testable import CatVodUI
import Testing

/// 假传输：搜索接口（POST）依次回候选列表，弹幕文件（GET）按地址回内容；不在表里的地址回 404。
///
/// 为什么要它：M03P25 之前这段接线**一点单测都没有**（只有 `danmakuStatus` 的文案被测过），
/// 而「搜索 → 候选 → 下载 → 解析 → 上屏数据」每一步都可能断。`AppModel` 现在有注入口
/// （`AppModel(danmakuTransport:)`，与 `downloadTransport` / `tmdbTransport` 同一套），
/// 整条链终于能离线跑一遍。
private actor DanmakuWiringTransport: HTTPTransport {
    /// 搜索接口依次回什么（用完之后一直回最后一个）。
    private var searchResponses: [String]
    /// 弹幕文件：地址 → 内容。
    private let files: [String: String]
    private var requested: [String] = []

    init(searchResponses: [String], files: [String: String]) {
        self.searchResponses = searchResponses
        self.files = files
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        requested.append(url)
        if request.method == .post {
            let body = searchResponses.count > 1
                ? searchResponses.removeFirst()
                : (searchResponses.first ?? "")
            return HTTPResponse(status: 200, body: Data(body.utf8))
        }
        guard let file = files[url] else {
            return HTTPResponse(status: 404)
        }
        return HTTPResponse(status: 200, body: Data(file.utf8))
    }

    func requestedURLs() -> [String] {
        requested
    }
}

/// 选弹幕的接线（M03P25）：注入假传输，把「搜索 → 候选 → 下载 → 解析」整条链离线跑一遍。
@Suite("播放页选弹幕：接线")
@MainActor
struct DanmakuSelectionTests {
    /// 一集的搜索请求（片名 / 集名在用例里不必区分）。
    private static let request = DanmakuRequest(name: "片名", episode: "第1集")

    private func makeModel(search: [String], files: [String: String]) throws -> AppModelFixture {
        let fixture = try AppModelFixture(
            danmakuTransport: DanmakuWiringTransport(searchResponses: search, files: files)
        )
        fixture.model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["http://127.0.0.1:1"])
        return fixture
    }

    @Test("载入一集：候选 = 站点自带 + 搜索到的；自动用站点自带那条，状态写清来源与条数")
    func loadMergesCandidates() async throws {
        let fixture = try makeModel(
            search: [#"[{"name":"搜到的","url":"http://d.example/searched.xml"}]"#],
            files: ["http://d.example/embedded.xml": #"<i><d p="1.0,1,25,16777215">站点自带</d></i>"#]
        )
        defer { fixture.tearDown() }

        let embedded = [DanmakuSource(name: "站点自带", url: "http://d.example/embedded.xml")]
        await fixture.model.loadDanmaku(Self.request, embedded: embedded)

        #expect(fixture.model.danmakuCandidates.map(\.name) == ["站点自带", "搜到的"])
        #expect(fixture.model.danmakuPick == nil)
        #expect(fixture.model.danmakuLines.count == 1)
        #expect(fixture.model.danmakuStatus == .loaded(source: "站点自带", count: 1))
    }

    @Test("手动换一条：当场换成它的行；回到自动：回第一条可用的")
    func selectAndBackToAuto() async throws {
        let fixture = try makeModel(
            search: [#"[{"name":"甲源","url":"http://d.example/a.xml"},{"name":"乙源","url":"http://d.example/b.xml"}]"#],
            files: [
                "http://d.example/a.xml": #"<i><d p="1.0,1,25,16777215">甲的</d></i>"#,
                "http://d.example/b.xml": #"<i><d p="2.0,1,25,16777215">乙一</d><d p="3.0,1,25,16777215">乙二</d></i>"#,
            ]
        )
        defer { fixture.tearDown() }

        await fixture.model.loadDanmaku(Self.request)
        #expect(fixture.model.danmakuStatus == .loaded(source: "甲源", count: 1))

        let second = try #require(fixture.model.danmakuCandidates.dropFirst().first)
        await fixture.model.selectDanmaku(second)
        #expect(fixture.model.danmakuPick == second)
        #expect(fixture.model.danmakuLines.count == 2)
        #expect(fixture.model.danmakuStatus == .loaded(source: "乙源", count: 2))

        await fixture.model.selectDanmaku(nil)
        #expect(fixture.model.danmakuPick == nil)
        #expect(fixture.model.danmakuLines.count == 1)
        #expect(fixture.model.danmakuStatus == .loaded(source: "甲源", count: 1))
    }

    @Test("选中的文件里没有行：说「里没有弹幕（换一条试试）」，不是「没搜到」")
    func emptyFileStatus() async throws {
        let fixture = try makeModel(
            search: [#"[{"name":"空文件","url":"http://d.example/empty.xml"}]"#],
            files: ["http://d.example/empty.xml": "<i></i>"]
        )
        defer { fixture.tearDown() }

        await fixture.model.loadDanmaku(Self.request)

        #expect(fixture.model.danmakuLines.isEmpty)
        #expect(fixture.model.danmakuStatus == .emptySource("空文件"))
    }

    @Test("重搜：新结果接进候选（去重、不丢原来的），且不动正在播的那份")
    func searchMergesCandidates() async throws {
        let fixture = try makeModel(
            search: [
                #"[{"name":"甲源","url":"http://d.example/a.xml"}]"#,
                #"[{"name":"甲源","url":"http://d.example/a.xml"},{"name":"新搜到的","url":"http://d.example/c.xml"}]"#,
            ],
            files: ["http://d.example/a.xml": #"<i><d p="1.0,1,25,16777215">甲的</d></i>"#]
        )
        defer { fixture.tearDown() }

        await fixture.model.loadDanmaku(Self.request)
        #expect(fixture.model.danmakuCandidates.map(\.name) == ["甲源"])

        let note = await fixture.model.searchDanmaku(name: "另一个名字", episode: "第2集")

        #expect(note == nil)
        #expect(fixture.model.danmakuLines.count == 1)
        #expect(fixture.model.danmakuCandidates.map(\.name) == ["甲源", "新搜到的"])
    }

    @Test("重搜搜不了时，把原因如实带回来（开关 / 关键词 / 地址三种）")
    func searchNotes() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        let disabled = await model.searchDanmaku(name: "片名", episode: "第1集")
        #expect(disabled == "弹幕 API 没开：设置 → 播放 → 弹幕 API")

        model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["http://127.0.0.1:1"])
        let blank = await model.searchDanmaku(name: " ", episode: "")
        #expect(blank == "片名和集名不能都是空的")

        model.danmakuAPI = DanmakuAPIConfig(isEnabled: true)
        let noAddress = await model.searchDanmaku(name: "片名", episode: "第1集")
        #expect(noAddress == "还没填弹幕 API 地址（设置 → 播放 → 弹幕 API）")
    }
}
