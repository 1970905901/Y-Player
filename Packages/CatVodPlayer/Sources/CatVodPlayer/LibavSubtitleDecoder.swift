import CatVodCore
import Foundation

#if canImport(Libavcodec)
import Libavcodec
#endif
#if canImport(Libavformat)
import Libavformat
#endif
#if canImport(Libavutil)
import Libavutil
#endif

/// 自研 FFmpeg 内核（M4）的**字幕解码层**（M04P19）：字幕包 → ``SubtitleCue``（文本）。
///
/// 定位（v1，写清楚免得期待错位）：
/// - **只出字**：文本轨（subrip / ass / ssa / mov_text / webvtt…）解成纯文本 cue，交给播放页
///   现成的 `SubtitleOverlay` 画 —— 与外部字幕走同一条路，不新造一套画法；
/// - **样式不还原**：ASS 的 `{\pos}` / 字体 / 卡拉OK 一律剥掉，只留文字（那是 libass 的活）；
/// - **位图轨不做**：PGS / DVD 这类解出来是图，连轨道清单里都不出现（不摆选了出不了字的选项）。
///
/// 并发：`@unchecked Sendable` —— 句柄由持有者串行使用（会话的解码线程）。
final class LibavSubtitleDecoder: @unchecked Sendable {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var timeBase = AVRational(num: 0, den: 1)
    private(set) var streamIndex = -1
    /// 解出过多少条 cue（排障 / 统计用）。
    private(set) var decodedCueCount = 0

    deinit {
        close()
    }

    /// 我们能出字的字幕编码（按 `avcodec_get_name` 的名字判，不猜）。
    ///
    /// 只列**真会遇到的**文本轨；位图轨（`hdmv_pgs_subtitle` / `dvd_subtitle` / `dvb_subtitle` /
    /// `xsub`）**不在里面** —— 认不出就不报给界面：宁可少报，也不给一个选了出不了字的选项。
    static func isTextCodec(_ codecName: String) -> Bool {
        switch codecName.lowercased() {
        case "subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text",
             "sami", "stl", "microdvd", "mpl2", "jacosub", "subviewer", "subviewer1",
             "vplayer", "realtext", "pjs":
            return true
        default:
            return false
        }
    }

    /// 给**指定的字幕流**建解码器。返回错误描述（nil = 成功）。
    func open(input: LibavInput, streamIndex index: Int) -> String? {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil)
        close()
        guard let formatContext = input.rawFormatContext else {
            return "输入还没打开"
        }
        guard input.streamKind(at: index) == .subtitle else {
            return "流 \(index) 不是字幕流"
        }
        guard let stream = formatContext.pointee.streams?[index],
              let parameters = stream.pointee.codecpar
        else {
            return "没有这条字幕流：\(index)"
        }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            return "没有字幕解码器：\(name)"
        }
        guard let codecContext = avcodec_alloc_context3(codec) else {
            return "字幕解码器上下文创建失败"
        }
        self.codecContext = codecContext
        guard avcodec_parameters_to_context(codecContext, parameters) >= 0 else {
            close()
            return "字幕解码参数拷贝失败"
        }
        guard avcodec_open2(codecContext, codec, nil) >= 0 else {
            let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            close()
            return "字幕解码器初始化失败：\(name)"
        }
        streamIndex = index
        timeBase = stream.pointee.time_base
        return nil
        #else
        _ = index
        return "Libav 模块不可用（本构建未链接）"
        #endif
    }

    /// 喂一只字幕包，解出 0..n 条 cue。
    ///
    /// 解不出就是空数组：字幕**不许**把播放带崩（这类包常有不规范的）。
    func feed(_ packet: UnsafeMutablePointer<AVPacket>) -> [SubtitleCue] {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil)
        guard let codecContext, packet.pointee.stream_index == Int32(streamIndex) else {
            return []
        }
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        let code = avcodec_decode_subtitle2(codecContext, &subtitle, &got, packet)
        guard code >= 0, got != 0 else {
            if code < 0 {
                let note = "字幕解码出错（流 \(streamIndex)）：\(LibavInput.errorText(code))"
                LibavTrace.logger.error("\(note, privacy: .public)")
            }
            return []
        }
        defer { avsubtitle_free(&subtitle) }
        // 时间口径：`start/end_display_time` 是**相对包时间**的毫秒（libav 的老规矩）。
        guard let base = Self.packetSeconds(
            pts: packet.pointee.pts,
            dts: packet.pointee.dts,
            timeBaseNumerator: timeBase.num,
            timeBaseDenominator: timeBase.den
        ) else {
            return []
        }
        let text = Self.text(from: subtitle)
        guard !text.isEmpty else {
            return []
        }
        let start = base + Double(subtitle.start_display_time) / 1000
        var end = base + Double(subtitle.end_display_time) / 1000
        if subtitle.end_display_time == UInt32.max || end <= start {
            // 结束时间没给（或给了个不合理的）：给固定兜底，不猜「显示到下一句」——
            // 那要往后看，而这条路是边读边出的。
            end = start + Self.fallbackDuration
        }
        decodedCueCount += 1
        return [SubtitleCue(start: start, end: end, text: text)]
        #else
        _ = packet
        return []
        #endif
    }

    /// 关闭（**幂等**）。
    func close() {
        #if canImport(Libavcodec)
        avcodec_free_context(&codecContext)
        #endif
        codecContext = nil
        streamIndex = -1
        timeBase = AVRational(num: 0, den: 1)
    }

    // MARK: - 纯映射（可单测）

    /// 结束时间解不出时的兜底时长（秒）。
    static let fallbackDuration: Double = 4

    /// 包的时间（秒）：pts 优先、没有就用 dts；两个都没有给 nil。
    ///
    /// 不直接复用 `LibavVideoDecoder.seconds`：那个把「无效 pts」当 0 —— 对视频帧没问题，
    /// 对字幕是灾难（整片字幕全挤到 0 秒）。签名同样不摆 `AVRational`（测试目标不继承包的 import）。
    static func packetSeconds(
        pts: Int64,
        dts: Int64,
        timeBaseNumerator: Int32,
        timeBaseDenominator: Int32
    ) -> Double? {
        let raw = pts != Int64.min ? pts : dts
        guard raw != Int64.min, timeBaseDenominator != 0 else {
            return nil
        }
        return Double(raw) * Double(timeBaseNumerator) / Double(timeBaseDenominator)
    }

    /// ASS / SSA 的文本加工：剥掉覆盖标签（`{\pos(1,2)}` 这类大括号块），
    /// 把 `\N` / `\n` 换行、`\h` 空格换成人能读的样子。
    static func stripASSTags(_ raw: String) -> String {
        var visible = ""
        var depth = 0
        for character in raw {
            switch character {
            case "{":
                depth += 1
            case "}" where depth > 0:
                depth -= 1
            default:
                if depth == 0 {
                    visible.append(character)
                }
            }
        }
        return visible
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把一条 `AVSubtitle` 的各个 rect 拼成文本（多行用换行连）。
    ///
    /// 只认文本 / ASS 两种 rect；位图轨的 `SUBTITLE_BITMAP` 跳过（我们不做图）。
    private static func text(from subtitle: AVSubtitle) -> String {
        #if canImport(Libavcodec)
        var parts: [String] = []
        for index in 0 ..< Int(subtitle.num_rects) {
            guard let rect = subtitle.rects?[index] else { continue }
            let raw: String?
            if rect.pointee.type == SUBTITLE_ASS, let ass = rect.pointee.ass {
                raw = String(cString: ass)
            } else if rect.pointee.type == SUBTITLE_TEXT, let plain = rect.pointee.text {
                raw = String(cString: plain)
            } else {
                raw = nil
            }
            guard let raw else { continue }
            let cleaned = stripASSTags(raw)
            if !cleaned.isEmpty {
                parts.append(cleaned)
            }
        }
        return parts.joined(separator: "\n")
        #else
        _ = subtitle
        return ""
        #endif
    }
}
