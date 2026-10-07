@testable import CatVodNode
import Foundation
import Testing

@Suite("Node 就绪行解析（对齐 js2p 契约）")
struct NodeReadinessTests {
    @Test("就绪行取实际端口")
    func exactLine() {
        #expect(NodeReadiness.port(fromLine: "CatVodSpiderios listening on http://127.0.0.1:9988") == 9988)
        #expect(NodeReadiness.isReadyLine("CatVodSpiderios listening on http://127.0.0.1:9999"))
    }

    @Test("EADDRINUSE 自增后的端口同样能解析")
    func portAfterConflict() {
        #expect(NodeReadiness.port(fromLine: "CatVodSpiderios listening on http://127.0.0.1:9993") == 9993)
        #expect(NodeReadiness.isPortConflictLine("Port 9988 is already in use. Trying next available port..."))
        #expect(!NodeReadiness.isPortConflictLine("CatVodSpiderios listening on http://127.0.0.1:9993"))
    }

    @Test("带前后缀与 CR 的行也能解析")
    func tolerantParsing() {
        #expect(NodeReadiness.port(fromLine: "[info] CatVodSpiderios listening on http://127.0.0.1:8123\r") == 8123)
        #expect(NodeReadiness.port(fromLine: "2026-10-07 CatVodSpiderios listening on http://127.0.0.1:3000 ") == 3000)
    }

    @Test("非就绪行与非法端口返回 nil")
    func rejectsInvalid() {
        #expect(NodeReadiness.port(fromLine: "messageToDart queryProfile") == nil)
        #expect(NodeReadiness.port(fromLine: "CatVodSpiderios listening on http://127.0.0.1:") == nil)
        #expect(NodeReadiness.port(fromLine: "CatVodSpiderios listening on http://127.0.0.1:70000") == nil)
        #expect(NodeReadiness.port(fromLine: "CatVodSpiderios listening on http://127.0.0.1:0") == nil)
        #expect(NodeReadiness.port(fromLine: "") == nil)
    }

    @Test("baseURL 固定回环地址")
    func baseURL() throws {
        let url = try #require(NodeReadiness.baseURL(port: 9988))
        #expect(url.absoluteString == "http://127.0.0.1:9988")
    }
}
