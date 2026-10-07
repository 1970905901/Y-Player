import CatVodCore
import Foundation
import Testing

@Suite("MD5（index.js.md5 校验）")
struct MD5Tests {
    @Test("RFC 1321 测试向量")
    func knownVectors() {
        #expect(MD5.hexDigest(of: "") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hexDigest(of: "abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MD5.hexDigest(of: "The quick brown fox jumps over the lazy dog") == "9e107d9d372bb6826bd81d3542a419d6")
        // 跨块（> 64 字节）输入
        let long = String(repeating: "a", count: 1000)
        #expect(MD5.hexDigest(of: long).count == 32)
        #expect(MD5.hexDigest(of: Data(long.utf8)) == MD5.hexDigest(of: long))
    }

    @Test("摘要比对大小写不敏感并忽略空白")
    func matches() {
        #expect(MD5.matches("35DCC10D533153DBB94298792664AD04", "35dcc10d533153dbb94298792664ad04"))
        #expect(MD5.matches(" 35dcc10d533153dbb94298792664ad04\n", "35dcc10d533153dbb94298792664ad04"))
        #expect(!MD5.matches("abc", "abd"))
    }
}

@Suite("配置入口定位（.js ↔ .js.md5）")
struct ConfigLocatorTests {
    @Test("JS 源配置：关联 .js.md5 校验地址与缓存名")
    func javascriptConfig() throws {
        let source = try #require(ConfigLocator.locate("https://9280.kstore.vip/ceshi/index.js"))
        #expect(source.kind == .javaScript)
        // 关键：校验地址是 index.js.md5，而不是 index.md5
        #expect(source.digestURL?.absoluteString == "https://9280.kstore.vip/ceshi/index.js.md5")
        #expect(source.cacheFileName.hasPrefix("config-"))
        #expect(source.cacheFileName.hasSuffix(".js"))
    }

    @Test("JSON 配置：无校验地址，缓存名为 .json")
    func jsonConfig() throws {
        let source = try #require(ConfigLocator.locate("https://example.com/tvbox/config.json"))
        #expect(source.kind == .json)
        #expect(source.digestURL == nil)
        #expect(source.cacheFileName.hasSuffix(".json"))
    }

    @Test("内联 JSON：按内容摘要生成缓存名")
    func inlineConfig() throws {
        let source = try #require(ConfigLocator.locate(#"{"sites":[]}"#))
        #expect(source.kind == .inline)
        #expect(source.url == nil)
        #expect(source.cacheFileName.hasPrefix("inline-"))
    }

    @Test("相对路径以配置文件为基准解析")
    func relativeResolution() throws {
        let base = try #require(URL(string: "https://example.com/tvbox/index.json"))
        let source = try #require(ConfigLocator.locate("./sub/config.json", relativeTo: base))
        #expect(source.url?.absoluteString == "https://example.com/tvbox/sub/config.json")
    }

    @Test("空输入与无法解析的相对路径返回 nil")
    func invalidInputs() {
        #expect(ConfigLocator.locate("   ") == nil)
        #expect(ConfigLocator.locate("./config.json") == nil)
    }

    @Test("是否需要重新下载的判定")
    func downloadDecision() {
        let digest = "35dcc10d533153dbb94298792664ad04"
        // 远端无摘要 → 必须下载
        #expect(ConfigLocator.needsDownload(remoteDigest: "", localDigest: digest))
        // 本地没有缓存 → 必须下载
        #expect(ConfigLocator.needsDownload(remoteDigest: digest, localDigest: nil))
        // 摘要一致 → 命中缓存
        #expect(!ConfigLocator.needsDownload(remoteDigest: digest, localDigest: digest))
        // 摘要不同 → 重新下载
        #expect(ConfigLocator.needsDownload(remoteDigest: digest, localDigest: MD5.hexDigest(of: "other")))
    }
}

@Suite("媒体直链嗅探")
struct MediaFormatSnifferTests {
    @Test("常见媒体扩展名")
    func extensions() {
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.m3u8"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.MP4"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.mkv"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.flv"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.m3u8?token=abc&e=1"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.m3u8#frag"))
    }

    @Test("非媒体地址")
    func nonMedia() {
        #expect(!MediaFormatSniffer.isVideoFormat("video-1001"))
        #expect(!MediaFormatSniffer.isVideoFormat("https://a/b.html"))
        #expect(!MediaFormatSniffer.isVideoFormat(""))
        #expect(!MediaFormatSniffer.isVideoFormat("https://a/page?id=x.m3u8"))
    }

    @Test("MIME 线索与本地文件")
    func mimeAndLocal() {
        #expect(MediaFormatSniffer.isVideoFormat("https://a/play?format=application/vnd.apple.mpegurl"))
        #expect(MediaFormatSniffer.isLocalFileURL("file:///tmp/a.mp4"))
        #expect(!MediaFormatSniffer.isLocalFileURL("https://a/b.mp4"))
    }
}
