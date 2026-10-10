@testable import CatVodPlayer
import Foundation
import Testing

/// 内嵌字幕解码层（M04P19）：能出字的编码白名单 + ASS 文本加工 + 包时间换算。
///
/// 真解码（`avcodec_decode_subtitle2`）要带字幕轨的片子 —— 现在的夹具造不出来
/// （AVAssetWriter 写文本轨又是一摊），所以这一层钉的是**纯映射**，
/// 真解码留给上机（与 M04P6 对输入层「能测的测、不能测的写清」同一套思路）。
@Suite("内嵌字幕解码（M04P19）")
struct LibavSubtitleDecoderTests {
    @Test("能出字的编码：文本轨都在，位图轨不在")
    func textCodecs() {
        for name in ["subrip", "ass", "ssa", "mov_text", "webvtt", "SRT", "TEXT"] {
            let ok = LibavSubtitleDecoder.isTextCodec(name)
            #expect(ok)
        }
        for name in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"] {
            let ok = LibavSubtitleDecoder.isTextCodec(name)
            #expect(!ok)
        }
    }

    @Test("ASS 文本加工：剥掉覆盖标签、换行 / 空格还原")
    func stripTags() {
        #expect(LibavSubtitleDecoder.stripASSTags("{\\pos(320,50)}你好") == "你好")
        #expect(LibavSubtitleDecoder.stripASSTags("{\\an8}上方{\\c&HFFFFFF&}白字") == "上方白字")
        #expect(LibavSubtitleDecoder.stripASSTags("上句\\N下句") == "上句\n下句")
        #expect(LibavSubtitleDecoder.stripASSTags("硬\\h空格") == "硬 空格")
        #expect(LibavSubtitleDecoder.stripASSTags("   ").isEmpty)
        // 不在大括号里的花括号：原样留着（不猜它是标签）
        #expect(LibavSubtitleDecoder.stripASSTags("a}b") == "a}b")
    }

    @Test("包时间：pts 优先、没有用 dts、都没有给 nil（宁可丢也不挤到 0 秒）")
    func packetSeconds() {
        let fromPTS = LibavSubtitleDecoder.packetSeconds(
            pts: 15360, dts: 0, timeBaseNumerator: 1, timeBaseDenominator: 15360
        )
        #expect(fromPTS == 1)
        let fromDTS = LibavSubtitleDecoder.packetSeconds(
            pts: Int64.min, dts: 30720, timeBaseNumerator: 1, timeBaseDenominator: 15360
        )
        #expect(fromDTS == 2)
        let neither = LibavSubtitleDecoder.packetSeconds(
            pts: Int64.min, dts: Int64.min, timeBaseNumerator: 1, timeBaseDenominator: 15360
        )
        #expect(neither == nil)
        let badTimeBase = LibavSubtitleDecoder.packetSeconds(
            pts: 100, dts: 0, timeBaseNumerator: 1, timeBaseDenominator: 0
        )
        #expect(badTimeBase == nil)
    }
}
