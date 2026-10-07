import CatVodCore
import Testing

@Suite("HLS 清单改写：对齐上游 M3u8.java")
struct HLSPlaylistRewriterTests {
    private let base = "https://cdn.example.com/live/index.m3u8"

    /// 测试用代理地址构造：只要能看到「哪条地址被换了」，不必真去百分号编码。
    private func proxied(_ url: String) -> String {
        "PROXY(" + url + ")"
    }

    @Test("清单判定：MIME 命中、扩展名命中（带 query 也算）、其它一律不算")
    func isPlaylist() {
        let mime = "application/vnd.apple.mpegurl; charset=utf-8"
        #expect(HLSPlaylistRewriter.isPlaylist(url: "https://cdn.example.com/live/a", contentType: mime))
        #expect(HLSPlaylistRewriter.isPlaylist(url: "https://cdn.example.com/live/a.m3u8?token=1"))
        #expect(HLSPlaylistRewriter.isPlaylist(url: "https://cdn.example.com/live/a.M3U"))
        #expect(!HLSPlaylistRewriter.isPlaylist(url: "https://cdn.example.com/live/a.ts", contentType: "video/mp2t"))
        #expect(!HLSPlaylistRewriter.isPlaylist(url: "https://cdn.example.com/live/a.mp4"))
    }

    @Test("文本判定：以 `#EXTM3U` 开头才算（前面允许空白）")
    func looksLikePlaylist() {
        #expect(HLSPlaylistRewriter.looksLikePlaylist("\n  #EXTM3U\n#EXT-X-VERSION:3"))
        #expect(!HLSPlaylistRewriter.looksLikePlaylist("<html>404</html>"))
        #expect(!HLSPlaylistRewriter.looksLikePlaylist(""))
    }

    @Test("改写分片：相对路径按清单地址解析，绝对路径原样，注释行不动")
    func rewriteSegments() {
        let playlist = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXTINF:5.0,",
            "seg1.ts",
            "#EXTINF:5.0,",
            "https://other.example.com/seg2.ts",
        ].joined(separator: "\n")
        let rewritten = HLSPlaylistRewriter.rewrite(playlist, baseURL: base, proxy: proxied)

        #expect(rewritten.contains("PROXY(https://cdn.example.com/live/seg1.ts)"))
        #expect(rewritten.contains("PROXY(https://other.example.com/seg2.ts)"))
        #expect(rewritten.contains("#EXTM3U"))
        #expect(rewritten.contains("#EXTINF:5.0,"))
        #expect(rewritten.components(separatedBy: "\n").count == 6)
    }

    @Test("改写子清单与 `URI=\"…\"`：只换地址，别的属性不许被误改")
    func rewriteAttributes() {
        let playlist = [
            "#EXTM3U",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x1",
            "#EXT-X-MAP:URI=\"https://cdn.example.com/init.mp4\"",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio/index.m3u8\"",
            "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360",
            "v360/index.m3u8",
        ].joined(separator: "\n")
        let rewritten = HLSPlaylistRewriter.rewrite(playlist, baseURL: base, proxy: proxied)

        #expect(rewritten.contains("URI=\"PROXY(https://cdn.example.com/live/key.bin)\""))
        #expect(rewritten.contains("URI=\"PROXY(https://cdn.example.com/init.mp4)\""))
        #expect(rewritten.contains("URI=\"PROXY(https://cdn.example.com/live/audio/index.m3u8)\""))
        #expect(rewritten.contains("GROUP-ID=\"a\""))
        #expect(rewritten.contains("PROXY(https://cdn.example.com/live/v360/index.m3u8)"))
    }

    @Test("地址解析：相对 / 根路径 / 协议相对 / 绝对；基准非法时原样返回")
    func resolve() {
        #expect(HLSPlaylistRewriter.resolve("seg.ts", against: base) == "https://cdn.example.com/live/seg.ts")
        #expect(HLSPlaylistRewriter.resolve("/root/seg.ts", against: base) == "https://cdn.example.com/root/seg.ts")
        #expect(HLSPlaylistRewriter.resolve("//other.example.com/x.ts", against: base) == "https://other.example.com/x.ts")
        #expect(HLSPlaylistRewriter.resolve("https://a.example.com/x.ts", against: base) == "https://a.example.com/x.ts")
        #expect(HLSPlaylistRewriter.resolve("seg.ts", against: "not a url") == "seg.ts")
    }

    @Test("引号不闭合时不猜：剩余内容原样保留")
    func brokenAttribute() {
        let broken = "#EXT-X-KEY:METHOD=AES-128,URI=\"key"
        #expect(HLSPlaylistRewriter.rewrite(broken, baseURL: base, proxy: proxied) == broken)
    }

    @Test("结尾换行保留（上游会吃掉，这里刻意保留：播放器更宽容）")
    func trailingNewline() {
        let playlist = "#EXTM3U\n#EXTINF:1.0,\nseg.ts\n"
        let rewritten = HLSPlaylistRewriter.rewrite(playlist, baseURL: base, proxy: proxied)
        #expect(rewritten.hasSuffix("PROXY(https://cdn.example.com/live/seg.ts)\n"))
    }
}
