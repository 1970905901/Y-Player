import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

// 换源测试的共享辅助（见 ChangeSourceServiceTests.swift）

/// 按站点 host 返回不同响应的假传输层（多站点换源必须能区分站点）。
actor RoutingSearchTransport: HTTPTransport {
    private let responses: [String: HTTPResponse]
    private var hosts: [String] = []

    init(responses: [String: HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let host = request.url.host ?? ""
        hosts.append(host)
        guard let response = responses[host] else {
            throw CatVodError.network(status: 0, url: request.url.absoluteString, reason: "未配置该站点的假响应")
        }
        return response
    }

    func requestedHosts() -> [String] {
        hosts
    }
}

func searchResponse(_ names: [String]) -> HTTPResponse {
    let body = names.enumerated()
        .map { index, name in #"{"vod_id":"\#(index + 1)","vod_name":"\#(name)"}"# }
        .joined(separator: ",")
    return HTTPResponse(status: 200, body: Data(#"{"code":0,"list":[\#(body)]}"#.utf8))
}

func cmsSite(_ key: String, changeable: Int = 1) -> Site {
    Site(key: key, name: key, type: 1, api: "https://\(key).example.com", changeable: changeable)
}

@Suite("换源：片名匹配度（启发式）")
struct ChangeSourceMatchTests {
    @Test("完全相同 / 标点与大小写归一化后相同")
    func exactMatches() {
        #expect(ChangeSourceService.matchScore(query: "海贼王", candidate: "海贼王") == 1)
        #expect(ChangeSourceService.matchScore(query: "One Piece", candidate: "onepiece") == 1)
        #expect(ChangeSourceService.matchScore(query: "《海贼王》", candidate: "海贼王") == 1)
    }

    @Test("前缀与包含")
    func prefixAndContains() {
        #expect(ChangeSourceService.matchScore(query: "海贼王", candidate: "海贼王 剧场版") == 0.85)
        #expect(ChangeSourceService.matchScore(query: "海贼", candidate: "航海海贼团") == 0.7)
    }

    @Test("字符重合度兜底与无关片名")
    func overlapAndUnrelated() {
        // 既不前缀也不包含，但字符集合完全一致 → 弱匹配
        #expect(ChangeSourceService.matchScore(query: "海贼王", candidate: "王贼海") == 0.5)
        // 完全无关 → 0（UI 不展示）
        #expect(ChangeSourceService.matchScore(query: "海贼王", candidate: "西游记") == 0)
        #expect(ChangeSourceService.matchScore(query: "   ", candidate: "海贼王") == 0)
    }
}
