import Foundation

/// 直播清单里的「设置行」状态机（上游 `LiveParser.Setting`）。
///
/// 为什么单独成类型：m3u 与 txt 两条解析路径共用同一套设置项 ——
/// `ua=` / `parse=` / `click=` / `format=` / `origin=` / `referer=` / `header=`、
/// `#EXTHTTP:`、`#EXTVLCOPT:http-*`、`#KODIPROP:inputstream.adaptive.*`。
/// 上游逐行**累积**这些设置，遇到一条可播放地址就把它们 `copy` 到当前频道；
/// 这里保持同样的时序（累积 → 应用到频道）。
///
/// 与上游的差别（均已记录）：
/// - DRM 相关（`license_key` / `license_type` / `drm_legacy`）本阶段**不解析**，属后续阶段；
/// - 取值一律「取关键字**第一次**出现之后到行尾」，而上游 `split(key)[1]` 在「值里又出现同名 key」时行为不同。
struct LivePlaylistSettings: Sendable {
    private(set) var ua = ""
    private(set) var parse: Int?
    private(set) var click = ""
    private(set) var format = ""
    private(set) var origin = ""
    private(set) var referer = ""
    private(set) var header: [String: String] = [:]

    /// 上游 `Setting.find(line)`：这一行是不是设置行。
    static func matches(_ line: String) -> Bool {
        let prefixes = [
            "ua", "parse", "click", "header", "format", "origin", "referer", "forceKey",
            "#EXTHTTP:", "#EXTVLCOPT:", "#KODIPROP:",
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }

    /// 上游 `Setting.check(line)`：解析这一行并累积到状态里。
    mutating func apply(_ line: String) {
        if line.hasPrefix("ua") {
            ua = Self.firstValue(of: ["user-agent=", "ua="], in: line)
        } else if line.hasPrefix("parse") {
            parse = Int(Self.firstValue(of: ["parse="], in: line))
        } else if line.hasPrefix("click") {
            click = Self.firstValue(of: ["click="], in: line)
        } else if line.hasPrefix("format") || line.contains("manifest_type=") {
            format = Self.mediaFormat(Self.firstValue(of: ["format=", "manifest_type="], in: line))
        } else if line.hasPrefix("origin") || line.hasPrefix("#EXTVLCOPT:http-origin") {
            origin = Self.firstValue(of: ["origin="], in: line)
        } else if line.hasPrefix("referer") || line.hasPrefix("#EXTVLCOPT:http-referrer") {
            referer = Self.firstValue(of: ["referer=", "referrer="], in: line)
        } else if line.hasPrefix("#EXTVLCOPT:http-user-agent") {
            ua = Self.firstValue(of: ["user-agent="], in: line)
        } else if line.hasPrefix("#EXTVLCOPT:http-cookie") {
            header["Cookie"] = Self.firstValue(of: ["cookie="], in: line)
        } else if line.hasPrefix("headers=") {
            applyHeaderList(Self.firstValue(of: ["headers="], in: line))
        } else if line.hasPrefix("#EXTHTTP:") || line.hasPrefix("header") {
            applyHeaderJSON(line)
        } else if line.contains("stream_headers=") || line.contains("common_headers=") {
            applyHeaderList(Self.firstValue(of: ["stream_headers=", "common_headers="], in: line))
        }
        // 其余（DRM / forceKey）本阶段刻意忽略，见类型文档。
    }

    /// 上游 `Setting.headers(line)`：`k=v&k2=v2`，也支持用 `|` 分成多段（每段再按 `&` 拆）。
    mutating func applyHeaderList(_ text: String) {
        for segment in text.split(separator: "|").map(String.init) {
            applyHeaderPairs(segment)
        }
    }

    /// 上游 `Setting.copy(channel)`：把累积的设置写进频道（**只写「这一行出现过」的字段**）。
    func applying(to channel: inout LiveChannel) {
        if !ua.isEmpty {
            channel.ua = ua
        }
        if let parse {
            channel.parse = parse
        }
        if !click.isEmpty {
            channel.click = click
        }
        if !format.isEmpty {
            channel.format = format
        }
        if !origin.isEmpty {
            channel.origin = origin
        }
        if !referer.isEmpty {
            channel.referer = referer
        }
        if !header.isEmpty {
            channel.header = header
        }
    }

    /// 上游 `Setting.clear()`：复位全部设置（txt 路径在 `#genre#` 处调用）。
    mutating func clear() {
        ua = ""
        parse = nil
        click = ""
        format = ""
        origin = ""
        referer = ""
        header = [:]
    }

    // MARK: - 内部

    /// 取关键字**第一次**出现之后到行尾的内容，去掉首尾空白与包裹的引号。
    static func firstValue(of keywords: [String], in line: String) -> String {
        var best: Range<String.Index>?
        for keyword in keywords {
            guard let range = line.range(of: keyword, options: [.caseInsensitive]) else {
                continue
            }
            if best == nil || range.lowerBound < best!.lowerBound {
                best = range
            }
        }
        guard let range = best else {
            return ""
        }
        let value = String(line[range.upperBound...])
        return value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// 上游 `Setting.format()` 的 MIME 归一化：`mpd`/`dash` → DASH，`hls` → HLS，其余原样。
    static func mediaFormat(_ value: String) -> String {
        switch value {
        case "mpd", "dash":
            "application/dash+xml"
        case "hls":
            "application/vnd.apple.mpegurl"
        default:
            value
        }
    }

    /// `#EXTHTTP:` / `header=` 后面是 JSON 对象。
    private mutating func applyHeaderJSON(_ line: String) {
        let json = line.hasPrefix("#EXTHTTP:")
            ? Self.firstValue(of: ["#EXTHTTP:"], in: line)
            : Self.firstValue(of: ["header="], in: line)
        guard let data = json.data(using: .utf8), let object = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        header.merge(object) { _, new in new }
    }

    /// `k=v&k2=v2` 形态（`#KODIPROP:…stream_headers=`）。
    private mutating func applyHeaderPairs(_ value: String) {
        for param in value.split(separator: "&") {
            let parts = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let text = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !key.isEmpty else {
                continue
            }
            header[key] = text
        }
    }
}
