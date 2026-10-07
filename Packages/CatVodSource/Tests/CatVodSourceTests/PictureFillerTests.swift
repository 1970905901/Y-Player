import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 固定返回 / 固定失败的假传输层。
actor PictureTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private let response: HTTPResponse?
    private let failure: CatVodError?

    init(response: HTTPResponse) {
        self.response = response
        failure = nil
    }

    init(failure: CatVodError) {
        response = nil
        self.failure = failure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let failure {
            throw failure
        }
        guard let response else {
            throw CatVodError.network(status: 0, url: request.url.absoluteString, reason: "无响应")
        }
        return response
    }

    func lastRequest() -> HTTPRequest? {
        requests.last
    }

    func count() -> Int {
        requests.count
    }
}

/// 列表项 JSON（`vod_pic` 可空，用来验证补图前后的差异）。
///
/// 只用「id + 封面」二元组、名称自动生成：元组最多 2 个成员（SwiftLint `large_tuple`）。
private func listJSON(_ items: [(id: String, pic: String)]) -> String {
    let body = items
        .map { #"{"vod_id":"\#($0.id)","vod_name":"条目\#($0.id)","vod_pic":"\#($0.pic)"}"# }
        .joined(separator: ",")
    return #"{"code":0,"page":1,"list":[\#(body)]}"#
}

private func decode(_ json: String) throws -> SpiderResult {
    try JSONDecoder().decode(SpiderResult.self, from: Data(json.utf8))
}

private func cmsSite(type: Int = 1) -> Site {
    Site(key: "cms\(type)", name: "CMS \(type)", type: type, api: "https://api.example.com")
}

@Suite("列表补图（对齐 pictureRequest）")
struct PictureFillerTests {
    @Test("缺图比例未达阈值时不补图")
    func belowThreshold() async throws {
        let json = listJSON([
            (id: "1", pic: "https://img.example.com/1.jpg"),
            (id: "2", pic: "https://img.example.com/2.jpg"),
            (id: "3", pic: ""),
        ])
        let result = try decode(json)
        let transport = PictureTransport(response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let filler = PictureFiller(client: CMSClient(transport: transport))

        #expect(!filler.needsFilling(site: cmsSite(), result: result))
        let filled = await filler.fill(site: cmsSite(), result: result)
        #expect(filled.list.count == 3)
        let requestCount = await transport.count()
        #expect(requestCount == 0)
    }

    @Test("缺图过半时补图，缺失封面被填上")
    func fillsMissingPictures() async throws {
        let needsFill = try decode(listJSON([
            (id: "1", pic: ""),
            (id: "2", pic: ""),
            (id: "3", pic: "https://img.example.com/3.jpg"),
        ]))
        let filledJSON = listJSON([
            (id: "1", pic: "https://img.example.com/1.jpg"),
            (id: "2", pic: "https://img.example.com/2.jpg"),
            (id: "3", pic: "https://img.example.com/3.jpg"),
        ])
        let transport = PictureTransport(response: HTTPResponse(status: 200, body: Data(filledJSON.utf8)))
        let filler = PictureFiller(client: CMSClient(transport: transport))

        #expect(filler.needsFilling(site: cmsSite(), result: needsFill))
        let filled = await filler.fill(site: cmsSite(), result: needsFill)
        // `allSatisfy` 是 rethrows：先在宏外算好再断言（Swift Testing 宏展开限制）。
        let allHavePictures = filled.list.allSatisfy { !$0.vodPic.isEmpty }
        #expect(allHavePictures)

        // 请求应带上 ids（逗号连接的 vod_id 列表）。
        let request = await transport.lastRequest()
        let url = request?.url.absoluteString ?? ""
        #expect(url.contains("ac=detail"))
        #expect(url.contains("ids=1,2,3"))
    }

    @Test("补图失败时原样返回（best-effort）")
    func failureKeepsOriginal() async throws {
        let original = try decode(listJSON([
            (id: "1", pic: ""),
            (id: "2", pic: ""),
        ]))
        let transport = PictureTransport(failure: CatVodError.network(status: 502, url: "https://api.example.com", reason: "上游不可用"))
        let filler = PictureFiller(client: CMSClient(transport: transport))

        let filled = await filler.fill(site: cmsSite(), result: original)
        // `allSatisfy` 是 rethrows：即使写成 key-path（SwiftFormat 会把闭包改成 `\.vodPic.isEmpty`），
        // 放进 `#expect` 宏也会炸 —— 必须在宏外算好。
        let allEmpty = filled.list.allSatisfy(\.vodPic.isEmpty)
        #expect(filled.list.count == 2)
        #expect(allEmpty)
    }

    @Test("不支持的站点类型不补图")
    func unsupportedKinds() throws {
        let json = listJSON([(id: "1", pic: "")])
        let result = try decode(json)
        let transport = PictureTransport(response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let filler = PictureFiller(client: CMSClient(transport: transport))

        #expect(!filler.needsFilling(site: cmsSite(type: 3), result: result))
        #expect(!filler.needsFilling(site: cmsSite(type: 4), result: result))
        // type=0（XML API）同样属于补图范围。
        #expect(filler.needsFilling(site: cmsSite(type: 0), result: result))

        let empty = SpiderResult()
        #expect(!filler.needsFilling(site: cmsSite(), result: empty))
    }
}
