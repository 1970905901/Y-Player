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

    @Test("加密：`AES-128` 的 key / IV 按片段存下来，`METHOD=NONE` 之后回到明文（M10k）")
    func detectsEncryption() {
        let encrypted = media("""
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00112233445566778899aabbccddeeff
        #EXTINF:4,
        seg.ts
        """)
        #expect(encrypted.isEncrypted)
        // AES-128 是这套链路认的加密，所以仍然可下（SAMPLE-AES 才不可下）
        #expect(encrypted.isDownloadable)
        #expect(encrypted.segmentKeys.count == 1)
        #expect(encrypted.segmentKeys[0]?.method == "AES-128")
        #expect(encrypted.segmentKeys[0]?.uri == "https://cdn.example/v/movie/key.bin")
        #expect(encrypted.segmentKeys[0]?.iv == "0x00112233445566778899aabbccddeeff")
        #expect(encrypted.segmentKeys[0]?.ivBytes()?.count == 16)

        let clear = media("""
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4,
        seg.ts
        """)
        #expect(!clear.isEncrypted)
        #expect(clear.segmentKeys == [nil])
    }

    @Test("缺省 IV = 该片段的媒体序号（16 字节大端）；密钥中途轮换跟着换（M10k）")
    func derivesIVFromMediaSequence() {
        let manifest = media("""
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-KEY:METHOD=AES-128,URI="a.key"
        #EXTINF:4,
        seg-7.ts
        #EXTINF:4,
        seg-8.ts
        #EXT-X-KEY:METHOD=AES-128,URI="b.key"
        #EXTINF:4,
        seg-9.ts
        """)
        #expect(manifest.segmentKeys.count == 3)
        // 7 / 8 号片段的缺省 IV 就是各自的媒体序号（大端 16 字节）
        #expect(manifest.segmentKeys[0]?.iv == "0x00000000000000000000000000000007")
        #expect(manifest.segmentKeys[1]?.iv == "0x00000000000000000000000000000008")
        // 换 key 之后 URI 跟着换，IV 继续按序号推
        #expect(manifest.segmentKeys[2]?.uri == "https://cdn.example/v/movie/b.key")
        #expect(manifest.segmentKeys[2]?.iv == "0x00000000000000000000000000000009")
    }

    @Test("init 片不带 KEY、也不吃媒体序号（M10k）")
    func initSegmentKeepsSequence() {
        let manifest = media("""
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="a.key"
        #EXTINF:4,
        seg-0.m4s
        """)
        #expect(manifest.segments.count == 2)
        #expect(manifest.segmentKeys[0] == nil)
        #expect(manifest.segmentKeys[1]?.iv == "0x" + String(repeating: "0", count: 32))
    }

    @Test("SAMPLE-AES：标出来且不可下（那是另一套规范），理由交给调用方说（M10k）")
    func refusesSampleAES() {
        let manifest = media("""
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"
        #EXTINF:4,
        seg.ts
        """)
        #expect(manifest.isEncrypted)
        #expect(manifest.hasUnsupportedEncryption)
        #expect(!manifest.isDownloadable)
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

    @Test("字节范围清单：按片段存 offset / length，缺 offset 时接上一段的结尾（M10l）")
    func parsesByteRanges() {
        let ranged = media("""
        #EXTINF:4,
        #EXT-X-BYTERANGE:1000@0
        all.ts
        #EXTINF:4,
        #EXT-X-BYTERANGE:500
        all.ts
        """)
        #expect(ranged.isRangeBased)
        #expect(ranged.segmentRanges.count == 2)
        #expect(ranged.segmentRanges[0] == HLSManifest.SegmentRange(offset: 0, length: 1000))
        // 第二段没写 offset：按 RFC 8216 = 上一段的结尾
        #expect(ranged.segmentRanges[1] == HLSManifest.SegmentRange(offset: 1000, length: 500))
        #expect(!ranged.hasUnresolvableRange)
        #expect(ranged.isDownloadable)

        // 明文、不带范围的普通清单照旧能下（范围那一列是 nil）
        #expect(media("#EXTINF:4,\nseg.ts").isDownloadable)
    }

    @Test("字节范围：第一段就没写 offset（不合 RFC）→ 整份如实拒绝，不猜（M10l）")
    func unresolvableByteRange() {
        let broken = media("""
        #EXTINF:4,
        #EXT-X-BYTERANGE:500
        all.ts
        """)
        #expect(broken.isRangeBased)
        #expect(broken.hasUnresolvableRange)
        #expect(broken.segmentRanges == [nil])
        #expect(!broken.isDownloadable)
    }

    @Test("续下指纹：同前缀稳定、前缀变了就变、后面长出新片段不影响前缀（M10n）")
    func resumeFingerprint() {
        let first = media("""
        #EXTINF:4,
        seg-1.ts
        #EXTINF:4,
        seg-2.ts
        """)
        let same = media("""
        #EXTINF:4,
        seg-1.ts
        #EXTINF:4,
        seg-2.ts
        """)
        #expect(first.segmentFingerprint(prefix: 2) == same.segmentFingerprint(prefix: 2))

        // 前缀里换了一片：指纹变（续下要靠它拦下「清单变过」）
        let changed = media("""
        #EXTINF:4,
        seg-1-other.ts
        #EXTINF:4,
        seg-2.ts
        """)
        #expect(first.segmentFingerprint(prefix: 2) != changed.segmentFingerprint(prefix: 2))

        // 清单后面长出新片段：前两片的指纹不动（续下不用整份重下）
        let grown = media("""
        #EXTINF:4,
        seg-1.ts
        #EXTINF:4,
        seg-2.ts
        #EXTINF:4,
        seg-3.ts
        """)
        #expect(first.segmentFingerprint(prefix: 2) == grown.segmentFingerprint(prefix: 2))
        #expect(first.segmentFingerprint(prefix: 3) != grown.segmentFingerprint(prefix: 3))

        // 同一个 URI 靠字节范围区分的那类清单（M10l）：范围不同 → 指纹不同
        let rangedA = media("#EXTINF:4,\n#EXT-X-BYTERANGE:100@0\nall.ts")
        let rangedB = media("#EXTINF:4,\n#EXT-X-BYTERANGE:100@100\nall.ts")
        #expect(rangedA.segmentFingerprint(prefix: 1) != rangedB.segmentFingerprint(prefix: 1))
    }

    @Test("注释、CRLF、多余空行都不影响解析")
    func toleratesNoise() {
        let manifest = HLSManifestParser.parse(text: "#EXTM3U\r\n# 注释行\r\n\r\n#EXTINF:4.5,\r\nseg.ts\r\n", baseURL: base)
        #expect(manifest.segments == ["https://cdn.example/v/movie/seg.ts"])
        #expect(manifest.totalDuration == 4.5)
    }
}
