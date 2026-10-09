@testable import CatVodCore
import Testing

@Suite("HLS 清单展开：要下哪些地址")
struct HLSManifestSegmentsTests {
    private let base = "https://cdn.example/v/movie/index.m3u8"

    private func media(_ body: String) -> HLSManifest {
        HLSManifestParser.parse(text: "#EXTM3U\n" + body, baseURL: base)
    }

    @Test("媒体清单：片段按顺序列出并绝对化，时长求和")
    func mediaSegments() {
        let manifest = media("""
        #EXT-X-VERSION:3
        #EXTINF:9.009,
        seg-1.ts

        #EXTINF:9.009,
        seg-2.ts
        #EXT-X-ENDLIST
        """)
        #expect(manifest.segments == [
            "https://cdn.example/v/movie/seg-1.ts",
            "https://cdn.example/v/movie/seg-2.ts",
        ])
        #expect(abs(manifest.totalDuration - 18.018) < 0.0001)
        #expect(!manifest.isMaster)
        #expect(manifest.hasContent)
    }

    @Test("相对地址按清单地址解析：`../` 这种写法自己拼必错")
    func resolvesRelativePaths() {
        let manifest = media("""
        #EXTINF:4,
        ../shared/seg-3.ts
        """)
        #expect(manifest.segments == ["https://cdn.example/v/shared/seg-3.ts"])
    }

    @Test("以 `/` 开头的是相对主机根，不是相对清单目录")
    func resolvesRootRelativePaths() {
        let manifest = media("""
        #EXTINF:4,
        /media/seg-4.ts
        """)
        #expect(manifest.segments == ["https://cdn.example/media/seg-4.ts"])
    }

    @Test("绝对地址原样保留（换成另一个 CDN 的片段很常见）")
    func keepsAbsolutePaths() {
        let manifest = media("""
        #EXTINF:4,
        https://other.example/a/seg-5.ts?token=1
        """)
        #expect(manifest.segments == ["https://other.example/a/seg-5.ts?token=1"])
    }

    @Test("主清单：变体地址与带宽，相对地址同样要绝对化")
    func masterVariants() {
        let manifest = HLSManifestParser.parse(text: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
        high/index.m3u8
        """, baseURL: base)
        #expect(manifest.isMaster)
        #expect(manifest.variants.map(\.bandwidth) == [800_000, 2_400_000])
        // 先绑变量再断言：`#expect` 对「map + 多行数组字面量」的宏展开在个别工具链版本上会失败，
        // 绑成局部 let 之后断言的是普通值，稳。
        let variantURLs = manifest.variants.map(\.url)
        #expect(variantURLs == [
            "https://cdn.example/v/movie/low/index.m3u8",
            "https://cdn.example/v/movie/high/index.m3u8",
        ])
        #expect(manifest.bestVariant?.url == "https://cdn.example/v/movie/high/index.m3u8")
    }

    @Test("选变体：带宽最高；并列或都没有带宽时取清单里的第一条")
    func bestVariantTieBreaksToFirst() {
        let tied = HLSManifestParser.parse(text: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100
        first.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=100
        second.m3u8
        """, baseURL: base)
        #expect(tied.bestVariant?.url == "https://cdn.example/v/movie/first.m3u8")

        let noBandwidth = HLSManifestParser.parse(text: """
        #EXTM3U
        #EXT-X-STREAM-INF:RESOLUTION=640x360
        only.m3u8
        #EXT-X-STREAM-INF:RESOLUTION=1280x720
        another.m3u8
        """, baseURL: base)
        #expect(noBandwidth.bestVariant?.url == "https://cdn.example/v/movie/only.m3u8")
    }

    @Test("加密：`AES-128` 标出来，`METHOD=NONE` 不算加密")
    func detectsEncryption() {
        let encrypted = media("""
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:4,
        seg.ts
        """)
        #expect(encrypted.isEncrypted)

        let clear = media("""
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4,
        seg.ts
        """)
        #expect(!clear.isEncrypted)
    }

    @Test("fMP4 的 init 片排在最前：漏了它整个文件播不了")
    func insertsMapSegmentFirst() {
        let manifest = media("""
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg-1.m4s
        #EXTINF:4,
        seg-2.m4s
        """)
        #expect(manifest.segments == [
            "https://cdn.example/v/movie/init.mp4",
            "https://cdn.example/v/movie/seg-1.m4s",
            "https://cdn.example/v/movie/seg-2.m4s",
        ])
        // 落盘后缀靠它决定（有 init 片 = MP4 分段流）
        #expect(manifest.hasInitializationSegment)
        #expect(!media("#EXTINF:4,\nseg.ts").hasInitializationSegment)
    }

    @Test("不是清单（比如直接的 mp4 文本/响应体）→ 空结果，调用方当普通文件直下")
    func nonPlaylistIsEmpty() {
        let manifest = HLSManifestParser.parse(text: "not a playlist at all", baseURL: base)
        #expect(!manifest.hasContent)
        #expect(!manifest.isMaster)
        #expect(manifest.segments.isEmpty)
    }

    @Test("字节范围清单（`#EXT-X-BYTERANGE`）标出来：不认它会「同一个文件下 N 遍」")
    func detectsByteRange() {
        let ranged = media("""
        #EXTINF:4,
        #EXT-X-BYTERANGE:1000@0
        all.ts
        #EXTINF:4,
        #EXT-X-BYTERANGE:1000@1000
        all.ts
        """)
        #expect(ranged.isRangeBased)
        #expect(!ranged.isDownloadable)
        // 明文、不带范围的普通清单就能下
        #expect(media("#EXTINF:4,\nseg.ts").isDownloadable)
    }

    @Test("注释、CRLF、多余空行都不影响解析")
    func toleratesNoise() {
        let manifest = HLSManifestParser.parse(text: "#EXTM3U\r\n# 注释行\r\n\r\n#EXTINF:4.5,\r\nseg.ts\r\n", baseURL: base)
        #expect(manifest.segments == ["https://cdn.example/v/movie/seg.ts"])
        #expect(manifest.totalDuration == 4.5)
    }
}
