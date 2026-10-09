import Foundation

/// 外挂字幕解析：SRT 与 WebVTT。
///
/// 上游不做这件事（ExoPlayer 内置），所以这里的规则是**按格式标准**定的，不逐行对齐谁。
/// 但两个格式的坑都很具体，逐条列在测试里：
///
/// - 换行 `\r\n` / `\r`、文件头 BOM —— 都得先归一化，否则第一块永远解不出来；
/// - SRT 的毫秒用**逗号**（`00:00:01,000`），VTT 用**点**（`00:00:01.000`），互相容错；
/// - VTT 允许 `MM:SS.mmm`（只有分秒）、cue 标识行、`NOTE` / `STYLE` 块、时间行后的设置
///   （`align:start position:10%`）—— 都得认出来并跳过，不然它们会被当成字幕文本；
/// - 解析完**按 `start` 排序**：文件里通常有序，但不保证，而后续取用是二分查找。
///
/// 刻意不做的事（写下来免得被当成遗漏）：
/// - **不剥离 `<i>` / `<b>` / `<v 说话人>` 之类的标签**，也不解 `&amp;` 这类实体 —— 原文照留，
///   怎么显示属于渲染层的决定；真要在纯文本场景用，应该在这里另出一个 `plainText`，
///   而不是让调用方各自去猜格式；
/// - 不处理 ASS/SSA（上游靠原生 ASS 库，iOS 上要么等 MPV 渲染路径，要么另起一轮）。
public enum SubtitleDocument {
    /// 解析字幕文本。
    ///
    /// - Parameters:
    ///   - format: 字幕源声明的 MIME（如 `application/x-subrip`、`text/vtt`），可空；
    ///   - url: 字幕地址，用来按扩展名兜底判定格式，可空。
    public static func parse(text: String, format: String = "", url: String = "") -> [SubtitleCue] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else {
            return []
        }
        let cues = isWebVTT(normalized, format: format, url: url)
            ? parseWebVTT(normalized)
            : parseSRT(normalized)
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - 判定与归一化

    /// 换行归一 + 去 BOM。
    private static func normalize(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        if value.hasPrefix("\u{FEFF}") {
            value.removeFirst()
        }
        return value
    }

    private static func isWebVTT(_ text: String, format: String, url: String) -> Bool {
        let lowerFormat = format.lowercased()
        if lowerFormat.contains("vtt") {
            return true
        }
        if url.lowercased().hasSuffix(".vtt") {
            return true
        }
        return text.hasPrefix("WEBVTT")
    }

    // MARK: - SRT

    /// SRT：`序号 / 时间行 / 文本…`，块之间用空行分隔。序号行可有可无。
    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in blocks(of: text) {
            var index = 0
            if index < block.count, isOrdinal(block[index]) {
                index += 1
            }
            guard index < block.count, let range = timeRange(in: block[index]) else {
                continue
            }
            let body = joined(block, from: index + 1)
            guard !body.isEmpty else {
                continue
            }
            cues.append(SubtitleCue(start: range.start, end: range.end, text: body))
        }
        return cues
    }

    // MARK: - WebVTT

    /// VTT：`WEBVTT` 头 + cue 块；另有 `NOTE` / `STYLE` 块要跳过。
    ///
    /// cue 块的第一行可能是**标识**（不含 `-->`），这时时间行在第二行 ——
    /// 认不出来就会把标识行当成字幕文本，屏幕上多出一行莫名其妙的字。
    private static func parseWebVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in blocks(of: text) {
            guard let first = block.first else {
                continue
            }
            if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") {
                continue
            }
            var index = 0
            if !first.contains("-->"), block.count > 1 {
                index = 1
            }
            guard index < block.count, let range = timeRange(in: block[index]) else {
                continue
            }
            let body = joined(block, from: index + 1)
            guard !body.isEmpty else {
                continue
            }
            cues.append(SubtitleCue(start: range.start, end: range.end, text: body))
        }
        return cues
    }

    // MARK: - 共用

    /// 按空行切块（行内空白保留，行尾空白不去 —— 文本原样最重要）。
    private static func blocks(of text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
                continue
            }
            current.append(line)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// 把块从 `index` 起的行拼成文本（多行 cue 用 `\n`）。
    private static func joined(_ block: [String], from index: Int) -> String {
        guard index < block.count else {
            return ""
        }
        return block[index...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 纯数字（SRT 的序号行）。
    private static func isOrdinal(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber)
    }

    /// 时间行：`00:00:01,000 --> 00:00:04,000`。
    ///
    /// VTT 在结束时间后还可能跟设置（`00:00:04.000 align:start position:10%`）——
    /// 只取第一个词，否则 `Double("04.000 align:start")` 解不出来，整条 cue 丢掉。
    private static func timeRange(in line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else {
            return nil
        }
        guard let start = seconds(from: parts[0]) else {
            return nil
        }
        let tail = parts[1].trimmingCharacters(in: .whitespaces)
        let endToken = tail.split(separator: " ").first.map(String.init) ?? tail
        guard let end = seconds(from: endToken) else {
            return nil
        }
        return (start, end)
    }

    /// `HH:MM:SS,mmm` / `HH:MM:SS.mmm` / `MM:SS.mmm` —— 逗号与点都认（SRT 与 VTT 各用一种）。
    private static func seconds(from text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count >= 2 else {
            return nil
        }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            total *= 60
            total += value
        }
        return total
    }
}
