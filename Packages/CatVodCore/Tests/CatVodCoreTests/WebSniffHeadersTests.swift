import CatVodCore
import Testing

@Suite("解析页 header 收敛：对齐上游 WebSniffHeaders")
struct WebSniffHeadersTests {
    private let webViewUserAgent = "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A; wv) AppleWebKit/537.36"
        + " Version/4.0 Chrome/120 Mobile Safari/537.36"

    /// 回填后应当得到的 UA（去掉 `; wv)` 与 ` Version/4.0`）。
    private let strippedUA = "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A) AppleWebKit/537.36"
        + " Chrome/120 Mobile Safari/537.36"

    @Test("媒体 UA 被丢弃，并用回落的浏览器 UA 顶上（去掉 `; wv)` 与 ` Version/4.0`）")
    func rejectsMediaUserAgent() {
        let page = WebSniffHeaders.forPage(
            headers: ["User-Agent": "okhttp/3.12", "Referer": "https://site.example.com/"],
            fallbackUserAgent: webViewUserAgent
        )
        #expect(page["User-Agent"] == strippedUA)
        #expect(page["Referer"] == "https://site.example.com/")
    }

    @Test("浏览器 UA 原样保留")
    func keepsBrowserUserAgent() {
        let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
        let page = WebSniffHeaders.forPage(headers: ["User-Agent": browser], fallbackUserAgent: "okhttp/4")
        #expect(page["User-Agent"] == browser)
    }

    @Test("丢了 UA 但回落 UA 也不是浏览器时，只删不补（宁可没有 UA）")
    func dropsWithoutFallback() {
        let page = WebSniffHeaders.forPage(headers: ["User-Agent": "okhttp/4"], fallbackUserAgent: "okhttp/4")
        #expect(page["User-Agent"] == nil)
        #expect(page.isEmpty)
    }

    @Test("UA 名大小写不敏感，其它 header 一律保留")
    func keepsOtherHeaders() {
        let page = WebSniffHeaders.forPage(
            headers: ["user-agent": "okhttp/4", "Cookie": "a=1", "Referer": "https://site.example.com/"],
            fallbackUserAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        )
        #expect(page["user-agent"] == nil)
        #expect(page["Cookie"] == "a=1")
        #expect(page["Referer"] == "https://site.example.com/")
        #expect(page["User-Agent"] == "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    }

    @Test("UA 判定与清洗")
    func helpers() {
        #expect(WebSniffHeaders.isBrowserUserAgent("Mozilla/5.0 (X11; Linux) Gecko/20100101 Firefox/120.0"))
        #expect(!WebSniffHeaders.isBrowserUserAgent("okhttp/3.12"))
        #expect(!WebSniffHeaders.isBrowserUserAgent(""))
        #expect(WebSniffHeaders.browserUserAgent("Mozilla/5.0 (Linux; Android 13; wv) Version/4.0") == "Mozilla/5.0 (Linux; Android 13)")
        #expect(WebSniffHeaders.isUserAgent("USER-AGENT"))
        #expect(!WebSniffHeaders.isUserAgent("Referer"))
    }
}
