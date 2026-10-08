import Foundation

/// 直播清单解析：把 m3u / txt / json 三种清单翻成 ``LiveSource`` 的分组与频道。
///
/// 逐条对齐上游 `api/parser/LiveParser.java`：
/// - **形态判定**：`^(?!.*#genre#).*#EXTM3U.*`（多行）命中即 m3u；文本是 JSON **数组**即 json；其余按 txt；
/// - 解析前统一换行（`\r\n`、`\r` → `\n`）；
/// - m3u：`#EXTM3U` 行取时移与 EPG（`tvg-url` / `url-tvg`）；`#EXTINF:` 行取频道名与属性
///   （`group-title` / `tvg-id` / `tvg-name` / `tvg-logo` / `tvg-chno` / `http-user-agent` / `catchup*`）；
///   紧随其后的第一条非 `#` 且含 `://` 的行是地址（`地址|设置` 的设置交给 ``LivePlaylistSettings``）；
/// - txt：`分组名,#genre#` 切分组，`频道名,url1#url2` 加频道（按**第一个**逗号切分）；
/// - 收尾：给没有号的频道按顺序补 `001`、`002`…，并把直播源级设置补进频道（``LiveChannel/inherit(from:)``）。
///
/// 与上游的差别（均已记录）：DRM（`license_key` 等）与 EPG 拉取/时移时间格式化属后续阶段；
/// 上游用「元信息频道名」（`更新时间…`）过滤的行，这里同样过滤（``isMetaChannel(_:)``）。
public struct LivePlaylistParser: Sendable {
    public init() { }

    /// 解析清单，返回**补全后**的直播源。
    ///
    /// - Parameter source: 已经带了源级设置（`name`/`ua`/`header`/`catchup`…）的直播源；
    ///   `groups` 非空时直接返回（与上游 `LiveParser.start` 的短路一致）。
    public func parse(_ text: String, into source: LiveSource) -> LiveSource {
        var result = source
        guard result.groups.isEmpty else {
            return result
        }
        if Self.isJSONArray(text) {
            parseJSON(text, into: &result)
        } else if Self.looksLikeM3U(text) {
            parseM3U(text, into: &result)
        } else {
            parseTXT(text, into: &result)
        }
        Self.finalize(&result)
        return result
    }
}

// MARK: - 形态判定与文本工具

extension LivePlaylistParser {
    /// 上游 `M3U` 正则 `^(?!.*#genre#).*#EXTM3U.*`（多行）的等价判定：
    /// **任意一行**同时满足「不含 `#genre#`」且「含 `#EXTM3U`」即为 m3u。
    public static func looksLikeM3U(_ text: String) -> Bool {
        lines(text).contains { !$0.contains("#genre#") && $0.contains("#EXTM3U") }
    }

    /// 上游 `Json.isArray(text)`：去掉空白后是 `[…]` 且能解析成 JSON。
    public static func isJSONArray(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return false
        }
        return (try? JSONDecoder().decode(AnyJSONValue.self, from: Data(trimmed.utf8))) != nil
    }

    /// 统一换行后按行切分（上游 `text.replace("\r\n","\n").replace("\r","")` 后 `split("\n")`）。
    static func lines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
    }

    /// 取 `key="…"` 属性（等价上游 `.*key="(.?|.+?)".*`：整行里找第一处，取引号内内容并去空白）。
    static func attribute(_ key: String, in line: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let groups = RegexScanner.groups(".*\(escaped)=\"(.?|.+?)\".*", in: line)
        guard groups.count > 1 else {
            return ""
        }
        return groups[1].trimmingCharacters(in: .whitespaces)
    }

    /// 上游 `extract(line, "tvg-url=", "url-tvg=")` 那一路：整行含关键字时取 `=` 后面的值。
    static func keywordValue(_ keywords: [String], in line: String) -> String {
        LivePlaylistSettings.firstValue(of: keywords, in: line)
    }

    /// `#EXTINF:` 行的频道名：上游 `.*,(.+?)$`（贪婪 `.*,` → 取**最后一个逗号**之后的内容）。
    static func channelName(in line: String) -> String {
        guard let lastComma = line.lastIndex(of: ",") else {
            return ""
        }
        let name = String(line[line.index(after: lastComma)...])
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// 上游 `isMetaChannel`：`更新时间…` 这一类是「源里的元信息」，不是真频道。
    static func isMetaChannel(_ name: String) -> Bool {
        let text = name.trimmingCharacters(in: .whitespaces).lowercased()
        let prefixes = ["更新时间", "更新日期", "update time", "update date", "last update"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    /// 上游 `isPlayableUrl`：含 `://` 才算地址。
    static func isPlayableURL(_ url: String) -> Bool {
        url.trimmingCharacters(in: .whitespaces).contains("://")
    }

    /// `#EXTM3U` 行里的 EPG 地址：先按属性取，再按关键字取（上游两套写法都试）。
    static func epgFromPlaylistHeader(_ line: String) -> String {
        let direct = attribute("tvg-url", in: line)
        if !direct.isEmpty {
            return direct
        }
        let alternate = attribute("url-tvg", in: line)
        if !alternate.isEmpty {
            return alternate
        }
        return keywordValue(["tvg-url=", "url-tvg="], in: line)
    }

    /// 上游 `live.find(Group.create(name, live.pass))`：同名分组返回下标，否则追加。
    ///
    /// 匹配只看**分组名**（与上游 `Group.equals` 的 `getName().equals(...)` 一致）：
    /// `A_1` 与 `A_2` 在「不拆密码」模式下算同一个分组。
    static func groupIndex(named name: String, skipSplit: Bool, in groups: inout [LiveGroup]) -> Int {
        let candidate = LiveGroup(name: name, skipPasswordSplit: skipSplit)
        if let index = groups.firstIndex(where: { $0.name == candidate.name }) {
            return index
        }
        groups.append(candidate)
        return groups.count - 1
    }

    /// 对「当前频道」做一次修改（下标越界时什么都不做）。
    static func withChannel(
        _ groups: inout [LiveGroup],
        _ reference: (group: Int, channel: Int)?,
        _ body: (inout LiveChannel) -> Void
    ) {
        guard let reference,
              groups.indices.contains(reference.group),
              groups[reference.group].channels.indices.contains(reference.channel)
        else {
            return
        }
        body(&groups[reference.group].channels[reference.channel])
    }

    /// 上游 `LiveParser.apply`：给没有号的频道按顺序补 `001`、`002`…，并把直播源级设置补进频道。
    static func finalize(_ source: inout LiveSource) {
        // 先拷一份当「源级设置模板」：`inherit(from:)` 需要读 source 的字段，同时又要改 groups，
        // 直接传 `source` 会触发「同时读写」的独占访问冲突。
        let template = source
        var number = 0
        for groupIndex in source.groups.indices {
            for channelIndex in source.groups[groupIndex].channels.indices {
                if source.groups[groupIndex].channels[channelIndex].number.isEmpty {
                    number += 1
                    source.groups[groupIndex].channels[channelIndex].number = String(format: "%03d", number)
                }
                source.groups[groupIndex].channels[channelIndex].inherit(from: template)
            }
        }
    }
}

// MARK: - m3u / txt / json

extension LivePlaylistParser {
    /// 上游 `LiveParser.m3u`。
    private func parseM3U(_ text: String, into source: inout LiveSource) {
        var settings = LivePlaylistSettings()
        var headerCatchup = LiveCatchup()
        var groups: [LiveGroup] = []
        var current: (group: Int, channel: Int)?

        for line in Self.lines(text) {
            if LivePlaylistSettings.matches(line) {
                settings.apply(line)
                continue
            }
            if line.hasPrefix("#EXTM3U") {
                headerCatchup.type = Self.attribute("catchup", in: line)
                headerCatchup.source = Self.attribute("catchup-source", in: line)
                headerCatchup.replace = Self.attribute("catchup-replace", in: line)
                if source.epg.isEmpty {
                    source.epg = Self.epgFromPlaylistHeader(line)
                }
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                let name = Self.channelName(in: line)
                guard !Self.isMetaChannel(name) else {
                    current = nil
                    continue
                }
                let groupIndex = Self.groupIndex(
                    named: Self.attribute("group-title", in: line),
                    skipSplit: source.pass,
                    in: &groups
                )
                let channelIndex = groups[groupIndex].indexOfChannel(named: name)
                current = (groupIndex, channelIndex)
                Self.withChannel(&groups, current) { channel in
                    channel.ua = Self.attribute("http-user-agent", in: line)
                    channel.tvgName = Self.attribute("tvg-name", in: line)
                    channel.number = Self.attribute("tvg-chno", in: line)
                    channel.logo = Self.attribute("tvg-logo", in: line)
                    channel.tvgID = Self.attribute("tvg-id", in: line)
                    let declared = LiveCatchup(
                        type: Self.attribute("catchup", in: line),
                        source: Self.attribute("catchup-source", in: line),
                        replace: Self.attribute("catchup-replace", in: line)
                    )
                    channel.catchup = LiveCatchup.decide(major: declared, minor: headerCatchup)
                }
                continue
            }
            guard let reference = current, !line.hasPrefix("#") else {
                continue
            }
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let url = parts.first, Self.isPlayableURL(url) else {
                continue
            }
            if parts.count > 1 {
                settings.applyHeaderList(parts[1])
            }
            Self.withChannel(&groups, reference) { channel in
                channel.urls.append(url.trimmingCharacters(in: .whitespaces))
                settings.applying(to: &channel)
            }
            settings.clear()
        }
        source.groups = groups
    }

    /// 上游 `LiveParser.txt`：`分组名,#genre#` 切分组，`频道名,url1#url2` 加频道。
    ///
    /// 注意与 m3u 的差别（照搬上游）：txt 路径**不**在每条地址后清空设置，
    /// 只在遇到 `#genre#` 时清空 —— 所以分组开头的设置会一直沿用到该分组结束。
    private func parseTXT(_ text: String, into source: inout LiveSource) {
        var settings = LivePlaylistSettings()
        var groups: [LiveGroup] = []

        for line in Self.lines(text) {
            if LivePlaylistSettings.matches(line) {
                settings.apply(line)
            }
            let split = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if line.contains("#genre#") {
                settings.clear()
                groups.append(LiveGroup(name: split.first ?? "", skipPasswordSplit: source.pass))
            }
            guard split.count > 1 else {
                continue
            }
            let name = split[0]
            if Self.isMetaChannel(name) {
                continue
            }
            for entry in split[1].split(separator: "#").map(String.init) {
                let parts = entry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let url = parts.first, Self.isPlayableURL(url) else {
                    continue
                }
                if groups.isEmpty {
                    groups.append(LiveGroup())
                }
                let groupIndex = groups.count - 1
                let channelIndex = groups[groupIndex].indexOfChannel(named: name)
                if parts.count > 1 {
                    settings.applyHeaderList(parts[1])
                }
                Self.withChannel(&groups, (groupIndex, channelIndex)) { channel in
                    channel.urls.append(url.trimmingCharacters(in: .whitespaces))
                    settings.applying(to: &channel)
                }
            }
        }
        source.groups = groups
    }

    /// 上游 `LiveParser.json`：清单本身就是「分组数组」（`Group.arrayFrom`）。
    private func parseJSON(_ text: String, into source: inout LiveSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), let groups = try? JSONDecoder().decode([LiveGroup].self, from: data) else {
            return
        }
        source.groups = groups
    }
}
