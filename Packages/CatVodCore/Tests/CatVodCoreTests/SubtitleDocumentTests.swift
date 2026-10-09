import CatVodCore
import Testing

/// 外挂字幕解析（M09a）：SRT 与 WebVTT。
///
/// 每条用例都对应 `SubtitleDocument` 注释里列出的一个坑。它们的共同点是
/// **不报错、只是字幕少一条或者多出一行怪字** —— 所以必须钉住。
@Suite("字幕解析")
struct SubtitleDocumentTests {
    private let srt = """
    1
    00:00:01,000 --> 00:00:04,000
    第一句

    2
    00:00:05,500 --> 00:00:08,000
    第二句
    """

    @Test("SRT 基本块：序号行 / 时间行 / 文本")
    func parsesSRT() {
        let cues = SubtitleDocument.parse(text: srt)

        #expect(cues.count == 2)
        #expect(cues.first?.start == 1)
        #expect(cues.first?.end == 4)
        #expect(cues.first?.text == "第一句")
        #expect(cues.last?.start == 5.5)
    }

    @Test("SRT 多行文本：用 `\\n` 连起来，不当成两条")
    func keepsMultiLineText() {
        let text = """
        1
        00:00:01,000 --> 00:00:03,000
        上面一行
        下面一行
        """

        let cues = SubtitleDocument.parse(text: text)

        #expect(cues.count == 1)
        #expect(cues.first?.text == "上面一行\n下面一行")
    }

    @Test("SRT 没有序号行也认（有些源直接给时间行）")
    func parsesSRTWithoutOrdinal() {
        let text = """
        00:00:02,000 --> 00:00:03,000
        裸时间行
        """

        let cues = SubtitleDocument.parse(text: text)

        #expect(cues.count == 1)
        #expect(cues.first?.start == 2)
        #expect(cues.first?.text == "裸时间行")
    }

    @Test("CRLF 换行 + BOM：第一块不能丢")
    func normalizesLineEndingsAndBOM() {
        let text = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\n带 BOM 的第一条\r\n"

        let cues = SubtitleDocument.parse(text: text)

        #expect(cues.count == 1)
        #expect(cues.first?.text == "带 BOM 的第一条")
    }

    @Test("VTT：`WEBVTT` 头 + 点做毫秒 + 标识行不当文本")
    func parsesWebVTT() {
        let text = """
        WEBVTT

        intro
        00:00:01.000 --> 00:00:04.000
        第一条

        00:00:05.000 --> 00:00:06.000
        第二条
        """

        let cues = SubtitleDocument.parse(text: text)

        #expect(cues.count == 2)
        #expect(cues.first?.text == "第一条") // 不是 "intro"
        #expect(cues.first?.start == 1)
        #expect(cues.last?.text == "第二条")
    }

    @Test("VTT：`NOTE` 与 `STYLE` 块跳过")
    func skipsVTTNotesAndStyles() {
        let text = """
        WEBVTT

        NOTE 这是一段注释
        它可能有很多行

        STYLE
        ::cue { color: yellow }

        00:00:02.000 --> 00:00:03.000
        真正的字幕
        """

        let cues = SubtitleDocument.parse(text: text)

        #expect(cues.count == 1)
        #expect(cues.first?.text == "真正的字幕")
    }

    @Test("VTT：时间行后面的设置（`align:` / `position:`）不能让整条丢掉")
    func ignoresVTTSettings() {
        let text = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000 align:start position:10%
        带设置的字幕
        """

        let cues = SubtitleDocument.parse(text: text)

        #expect(cues.count == 1)
        #expect(cues.first?.end == 2)
        #expect(cues.first?.text == "带设置的字幕")
    }

    @Test("VTT：允许只有分秒（`MM:SS.mmm`）")
    func acceptsShortVTTTimestamp() {
        let text = """
        WEBVTT

        01:30.500 --> 01:32.000
        一分三十秒
        """

        let cues = SubtitleDocument.parse(text: text)

        #expect(cues.count == 1)
        #expect(cues.first?.start == 90.5)
    }

    @Test("按 `format` / `url` 判定 VTT（正文没有 `WEBVTT` 头时也要认出来）")
    func detectsVTTByMetadata() {
        let text = "00:00:01.000 --> 00:00:02.000\n正文"

        #expect(SubtitleDocument.parse(text: text, format: "text/vtt").count == 1)
        #expect(SubtitleDocument.parse(text: text, url: "https://a.example.com/a.VTT").count == 1)
    }

    @Test("乱序输入按 `start` 排序（后续取用是二分查找，必须有序）")
    func sortsByStart() {
        let text = """
        1
        00:00:10,000 --> 00:00:12,000
        晚的

        2
        00:00:02,000 --> 00:00:03,000
        早的
        """

        let cues = SubtitleDocument.parse(text: text)
        let starts = cues.map(\.start)

        #expect(starts == [2, 10])
    }

    @Test("空输入 / 垃圾输入：返回空，不抛也不崩")
    func handlesGarbage() {
        #expect(SubtitleDocument.parse(text: "").isEmpty)
        #expect(SubtitleDocument.parse(text: "   \n\n  ").isEmpty)
        #expect(SubtitleDocument.parse(text: "这不是字幕").isEmpty)
        #expect(SubtitleDocument.parse(text: "1\n不是时间行\n文本").isEmpty)
    }

    @Test("边界：`isVisible` 含结束那一刻（与弹幕调度同一套口径）")
    func visibilityIncludesEnd() throws {
        let cue = try #require(SubtitleDocument.parse(text: srt).first)

        #expect(cue.isVisible(at: 1))
        #expect(cue.isVisible(at: 4))
        #expect(!cue.isVisible(at: 4.1))
        #expect(!cue.isVisible(at: 0.9))
    }
}
