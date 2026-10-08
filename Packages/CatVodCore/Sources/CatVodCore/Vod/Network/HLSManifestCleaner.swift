import Foundation

/// HLS 清单广告清理（**纯文本处理**：不发请求、不改 URI —— 拉流与代理改写在外面）。
///
/// 逐条对齐参考实现 `app/src/main/java/com/fongmi/android/tv/utils/HlsManifestCleaner.java`：
///
/// - **信号制**：一条规则命中需要凑够 `minimumSignals` 个**互相独立**的信号
///   （分片 host 后缀 / 分片 URL 正则 / 时长区间 / `#EXT-X-DISCONTINUITY` / 跨域），信号不够就不删；
/// - **只删完整条目**：只有 `#EXTINF` 开头的片段会被判定，孤立标签原样留着；
/// - **多处「宁可不删」**（``Result/fallback`` 为 true）：字节范围清单、低延迟清单
///   （`#EXT-X-SKIP:` / `#EXT-X-PART:` / `#EXT-X-PRELOAD-HINT:`）、删除比例超过 35%、
///   删除总时长超过 90 秒、直播清单里删到中间段、序列号会溢出 —— 任何一条成立就原样返回；
/// - 命中时连带丢掉片段前面的 `#EXT-X-DISCONTINUITY` / `#EXT-X-PROGRAM-DATE-TIME`
///   （但**不丢** `#EXT-X-KEY` / `#EXT-X-MAP`），直播清单还要把
///   `#EXT-X-MEDIA-SEQUENCE` / `#EXT-X-DISCONTINUITY-SEQUENCE` 往前推。
///
/// 为什么这么保守：清单是播放器的唯一依据，删错一段就是「画面缺一块 / 时间轴错位」，
/// 而规则来自社区配置（可能过时）。所以这里的原则是「**证据不足就别动手**」。
public enum HLSManifestCleaner {
    /// 删除比例上限：超过就整体放弃。
    public static let maxRemovalRatio = 0.35
    /// 删除总时长上限（秒）。
    public static let maxRemovedDurationSec = 90.0
    /// 清单体积上限（字符）。
    public static let maxManifestChars = 2 * 1024 * 1024
    /// 清单行数上限。
    public static let maxManifestLines = 20000
    /// 单条规则的编译正则条数上限。
    public static let maxRegexCount = 32
    /// 单条正则的长度上限。
    public static let maxRegexLength = 512

    // MARK: - 结果

    /// 清理结果。`fallback == true` 或 `changed == false` 时，`manifest` 与输入**逐字节相同**。
    public struct Result: Sendable, Equatable {
        /// 清理后的清单（没改动就是原样）。
        public let manifest: String
        /// 是否真的删掉了片段。
        public let changed: Bool
        /// 是否因为安全策略放弃处理（清单照旧；调用方可以据此上报原因）。
        public let fallback: Bool
        /// 删掉的片段数。
        public let removedSegments: Int
        /// 删掉的片段总时长（秒）。
        public let removedDurationSec: Double
        /// 每条规则各删了几段（键是规则 id；只有真删过的规则才会出现）。
        public let ruleCounts: [String: Int]
        /// 每个被删片段的明细（「跳过广告」提示与日志用）。
        public let removedSegmentDetails: [RemovedSegment]

        static func unchanged(_ manifest: String) -> Result {
            Result(
                manifest: manifest,
                changed: false,
                fallback: false,
                removedSegments: 0,
                removedDurationSec: 0,
                ruleCounts: [:],
                removedSegmentDetails: []
            )
        }

        static func fallback(_ manifest: String) -> Result {
            Result(
                manifest: manifest,
                changed: false,
                fallback: true,
                removedSegments: 0,
                removedDurationSec: 0,
                ruleCounts: [:],
                removedSegmentDetails: []
            )
        }
    }

    /// 被删掉的片段。
    public struct RemovedSegment: Sendable, Equatable {
        /// 分片所在域名（解析不出来时是空串）。
        public let adDomain: String
        /// 命中规则的 id。
        public let ruleID: String
        /// 在清单里的起播偏移（秒）。
        public let startSeconds: Double
        /// 片段时长（秒）。
        public let durationSec: Double
    }

    /// 规则编译 / 清理过程中的失败原因。
    public enum Failure: Error, Equatable {
        /// 缺 id（参考实现会直接拒掉）。
        case missingRuleID
        /// 既没有 `playlistHostSuffixes` 也没有 `playlistHostRegex`：规则没有作用域，不允许。
        case missingPlaylistScope
        /// `segmentUrlRegex` 里有空串。
        case emptySegmentRegex
        /// `hostSuffixes` 里有空串/空白项（「分片 host 后缀」不能是空串）。
        case invalidSegmentHost
        /// `minDuration` / `maxDuration` 只给了一个，或范围不合法。
        case incompleteDurationRange
        /// 时长区间不合法（负数 / 上界小于下界 / 非有限）。
        case invalidDurationRange
        /// `minimumSignals` 非法（≤ 0，或大于这条规则可用的信号数）。
        case invalidMinimumSignals
        /// 正则条数超限。
        case tooManyPatterns(Int)
        /// 正则太长，或属于「危险模式」（连续 `.*`／嵌套量词这类容易回溯爆炸的写法）。
        case unsafePattern(String)
        /// `#EXTINF` 的时长解析不出来。
        case invalidDuration(String)
        /// 序列号不合法（负数 / 超 64 位 / 加完溢出）。
        case invalidSequence(String)
    }

    // MARK: - 规则

    /// 一条已编译的规则（``HLSAdRule/compile()`` 的产物）。
    public struct Rule: Sendable {
        public let id: String
        /// 分片 host 后缀（命中即算一个信号）。
        public let hostSuffixes: [String]
        /// 清单 host 后缀（作用域：清单本身必须命中，整条规则才会被考虑）。
        public let playlistHostSuffixes: [String]
        /// 清单 host 正则（作用域，与后缀是「或」的关系）。
        public let playlistHostPatterns: [NSRegularExpression]
        /// 分片 URL 正则（命中即算一个信号）。
        public let segmentUrlPatterns: [NSRegularExpression]
        public let minimumSignals: Int
        /// 时长区间（含两端）；nil 表示不用时长做信号。
        public let durationRange: ClosedRange<Double>?
        public let requireDiscontinuity: Bool
        public let requireCrossDomain: Bool

        /// 编译一条规则。
        ///
        /// 分工与参考实现一致：**这里只校验正则**（条数/长度/危险模式），字段级校验在 ``HLSAdRule/compile()``。
        public init(
            id: String = "unnamed",
            hostSuffixes: [String] = [],
            playlistHostSuffixes: [String] = [],
            playlistHostPatterns: [String] = [],
            segmentUrlPatterns: [String] = [],
            durationRange: ClosedRange<Double>? = nil,
            requireDiscontinuity: Bool = false,
            requireCrossDomain: Bool = false,
            minimumSignals: Int = 1
        ) throws {
            let trimmedID = id.trimmingCharacters(in: .whitespaces)
            self.id = trimmedID.isEmpty ? "unnamed" : trimmedID
            self.hostSuffixes = hostSuffixes
            self.playlistHostSuffixes = playlistHostSuffixes
            self.playlistHostPatterns = try Self.compilePatterns(playlistHostPatterns)
            self.segmentUrlPatterns = try Self.compilePatterns(segmentUrlPatterns)
            self.durationRange = durationRange
            self.requireDiscontinuity = requireDiscontinuity
            self.requireCrossDomain = requireCrossDomain
            self.minimumSignals = max(1, minimumSignals)
        }

        /// 这条规则有没有作用域（后缀或正则至少一个）。
        var hasPlaylistScope: Bool {
            !playlistHostSuffixes.isEmpty || !playlistHostPatterns.isEmpty
        }

        /// 声明了时长区间。
        var hasDurationRange: Bool {
            durationRange != nil
        }

        /// 正则编译：条数、长度、危险模式三道闸（参考实现同样三道）。
        private static func compilePatterns(_ values: [String]) throws -> [NSRegularExpression] {
            guard values.count <= maxRegexCount else {
                throw Failure.tooManyPatterns(values.count)
            }
            return try values.map { value in
                guard !value.isEmpty, value.count <= maxRegexLength, !looksDangerous(value) else {
                    throw Failure.unsafePattern(value)
                }
                do {
                    return try NSRegularExpression(pattern: value)
                } catch {
                    throw Failure.unsafePattern(value)
                }
            }
        }

        /// 「危险模式」：连续 `.*` / `.+`，或对带量词的分组再套量词（`(a+)*` 那种回溯爆炸写法）。
        static func looksDangerous(_ value: String) -> Bool {
            value.contains(".*.*") || value.contains(".+.+") || hasRepeatedGroupQuantifier(value)
        }

        /// `(...[+*]...)[+*]` 形态：用一次括号/量词扫描判断，避免为正则本身再写一条复杂正则。
        private static func hasRepeatedGroupQuantifier(_ value: String) -> Bool {
            let characters = Array(value)
            var depth = 0
            var quantifierInside = false
            for (index, character) in characters.enumerated() {
                switch character {
                case "(":
                    depth += 1
                    quantifierInside = false
                case ")":
                    depth -= 1
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    if depth >= 0, quantifierInside, next == "+" || next == "*" {
                        return true
                    }
                    quantifierInside = false
                case "+", "*":
                    if depth > 0 {
                        quantifierInside = true
                    }
                default:
                    break
                }
            }
            return false
        }
    }

    // MARK: - 清理

    /// 清理清单。**没改动就逐字节返回输入**（`fallback` 为 true 时也一样）。
    ///
    /// - Parameters:
    ///   - baseURL: 清单自身的地址（解析相对分片地址、判断是否跨域都靠它）。
    ///   - manifest: 清单文本。
    ///   - rules: 已编译的规则。**启用状态由上层筛好再传进来** —— 这里只管匹配，不管谁打开。
    public static func clean(baseURL: String, manifest: String, rules: [Rule]) -> Result {
        guard !rules.isEmpty, manifest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            return Result.unchanged(manifest)
        }
        if manifest.count > maxManifestChars || lineCount(manifest) > maxManifestLines {
            return Result.fallback(manifest)
        }
        // 字节范围 / 低延迟清单的「片段边界」语义完全不同，直接不动。
        if manifest.contains("#EXT-X-BYTERANGE") {
            return Result.fallback(manifest)
        }
        if manifest.contains("#EXT-X-SKIP:") || manifest.contains("#EXT-X-PART:")
            || manifest.contains("#EXT-X-PRELOAD-HINT:")
        {
            return Result.fallback(manifest)
        }
        do {
            var nodes = try parse(manifest)
            var segmentCount = 0
            var removedCount = 0
            var mediaOffset = 0.0
            var removedDuration = 0.0
            var ruleCounts: [String: Int] = [:]
            var details: [RemovedSegment] = []

            for index in nodes.indices where nodes[index].uri != nil {
                segmentCount += 1
                let segmentDuration = nodes[index].durationSec
                if let rule = matchRule(baseURL: baseURL, segment: nodes[index], rules: rules) {
                    nodes[index].removed = true
                    removedCount += 1
                    removedDuration += segmentDuration
                    ruleCounts[rule.id, default: 0] += 1
                    details.append(RemovedSegment(
                        adDomain: resolvedURL(segmentURI: nodes[index].uri, baseURL: baseURL)?.host?.lowercased() ?? "",
                        ruleID: rule.id,
                        startSeconds: mediaOffset,
                        durationSec: segmentDuration
                    ))
                }
                mediaOffset += segmentDuration
            }

            if removedCount == 0 {
                return Result.unchanged(manifest)
            }
            // 杀太狠就别杀了：全删、超过 35%、或总时长超过 90 秒都当成「规则不可信」。
            if segmentCount == 0 || removedCount == segmentCount
                || Double(removedCount) / Double(segmentCount) > maxRemovalRatio
                || removedDuration > maxRemovedDurationSec
            {
                return Result.fallback(manifest)
            }

            var mediaSequenceIncrement = 0
            var discontinuitySequenceIncrement = 0
            if !manifest.contains("#EXT-X-ENDLIST") {
                var retainedSeen = false
                for node in nodes where node.uri != nil {
                    if node.removed {
                        // 直播清单里删中间段会让后面的序号整体错位 —— 宁可不删（只允许删开头那几段）。
                        if retainedSeen {
                            return Result.fallback(manifest)
                        }
                        mediaSequenceIncrement += 1
                        if node.discontinuityBefore {
                            discontinuitySequenceIncrement += 1
                        }
                    } else {
                        retainedSeen = true
                    }
                }
                if mediaSequenceIncrement > 0, !manifest.contains("#EXT-X-MEDIA-SEQUENCE:") {
                    return Result.fallback(manifest)
                }
                if discontinuitySequenceIncrement > 0, !manifest.contains("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                    return Result.fallback(manifest)
                }
            }

            return try Result(
                manifest: render(
                    nodes,
                    trailingNewline: manifest.hasSuffix("\n"),
                    mediaSequenceIncrement: mediaSequenceIncrement,
                    discontinuitySequenceIncrement: discontinuitySequenceIncrement
                ),
                changed: true,
                fallback: false,
                removedSegments: removedCount,
                removedDurationSec: removedDuration,
                ruleCounts: ruleCounts,
                removedSegmentDetails: details
            )
        } catch {
            // 任何解析/序列号问题都当「这份清单我不懂」处理，绝不冒险输出半成品。
            return Result.fallback(manifest)
        }
    }

    // MARK: - 解析

    /// 解析出来的一行或一段：`uri == nil` 是普通标签行，否则是一个片段。
    private struct Node {
        /// 片段前面的标签行（普通行节点就只有这一行）。
        var leading: [String]
        /// 片段地址；非 nil 表示这是片段节点。
        var uri: String?
        var durationSec: Double
        var discontinuityBefore: Bool
        var removed: Bool

        /// 这个节点要输出的行。
        var outputLines: [String] {
            guard let uri else { return leading }
            return leading + [uri]
        }

        static func line(_ value: String) -> Node {
            Node(leading: [value], uri: nil, durationSec: 0, discontinuityBefore: false, removed: false)
        }
    }

    private static func lineCount(_ value: String) -> Int {
        value.reduce(1) { count, character in character == "\n" ? count + 1 : count }
    }

    /// 把清单切成节点：`#EXTINF` 后面的第一行非标签行才算片段，其余都是独立行。
    private static func parse(_ manifest: String) throws -> [Node] {
        let normalized = manifest
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var nodes: [Node] = []
        var pending: [String] = []
        var discontinuityBefore = false

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty, pending.isEmpty {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#EXT-X-DISCONTINUITY" {
                discontinuityBefore = true
            }
            if trimmed.hasPrefix("#EXTINF:") {
                flush(&nodes, pending: &pending)
                pending.append(line)
                continue
            }
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                if hasExtInf(pending) {
                    try nodes.append(Node(
                        leading: pending,
                        uri: line,
                        durationSec: duration(pending),
                        discontinuityBefore: discontinuityBefore,
                        removed: false
                    ))
                    pending.removeAll()
                    discontinuityBefore = false
                } else {
                    flush(&nodes, pending: &pending)
                    nodes.append(.line(line))
                }
            } else {
                pending.append(line)
            }
        }
        flush(&nodes, pending: &pending)
        return nodes
    }

    private static func flush(_ nodes: inout [Node], pending: inout [String]) {
        for line in pending {
            nodes.append(.line(line))
        }
        pending.removeAll()
    }

    private static func hasExtInf(_ lines: [String]) -> Bool {
        lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTINF:") }
    }

    /// `#EXTINF:<秒>,<标题>` 里的秒数。解析不出来按参考实现**抛错**（整份清单走 fallback，不猜 0）。
    private static func duration(_ lines: [String]) throws -> Double {
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("#EXTINF:") else { continue }
            let start = value.index(value.startIndex, offsetBy: 8)
            let end = value.firstIndex(of: ",") ?? value.endIndex
            let number = String(value[start ..< end])
            guard let seconds = Double(number) else {
                throw Failure.invalidDuration(number)
            }
            return seconds
        }
        return 0
    }

    /// 相对分片地址 → 绝对地址（Swift 的 `URL` 比 Java 的 `URI` 严格，解析不出来返回 nil）。
    private static func resolvedURL(segmentURI: String?, baseURL: String) -> URL? {
        guard let segmentURI else { return nil }
        return URL(string: segmentURI, relativeTo: URL(string: baseURL))
    }

    // MARK: - 匹配

    /// 第一条命中的规则（**顺序敏感**：与参考实现一样取「第一条凑够信号的」）。
    private static func matchRule(baseURL: String, segment: Node, rules: [Rule]) -> Rule? {
        let resolved = resolvedURL(segmentURI: segment.uri, baseURL: baseURL)
        let url = resolved?.absoluteString ?? (segment.uri ?? "")
        let host = resolved?.host?.lowercased() ?? ""
        let baseHost = URL(string: baseURL)?.host?.lowercased() ?? ""

        for rule in rules {
            if rule.hasPlaylistScope {
                let scopedBySuffix = !rule.playlistHostSuffixes.isEmpty
                    && matchesHost(baseHost, suffixes: rule.playlistHostSuffixes)
                let scopedByPattern = !rule.playlistHostPatterns.isEmpty
                    && matchesPattern(baseHost, patterns: rule.playlistHostPatterns)
                if !scopedBySuffix, !scopedByPattern {
                    continue
                }
            }
            var signals = 0
            if matchesHost(host, suffixes: rule.hostSuffixes) {
                signals += 1
            }
            if matchesPattern(url, patterns: rule.segmentUrlPatterns) {
                signals += 1
            }
            if let range = rule.durationRange, range.contains(segment.durationSec) {
                signals += 1
            }
            if rule.requireDiscontinuity, segment.discontinuityBefore {
                signals += 1
            }
            if rule.requireCrossDomain, !host.isEmpty, !baseHost.isEmpty, host != baseHost {
                signals += 1
            }
            if signals >= rule.minimumSignals {
                return rule
            }
        }
        return nil
    }

    /// host 后缀匹配：相等，或 `.` + 后缀（参考实现 `matchesHost`）。
    private static func matchesHost(_ host: String, suffixes: [String]) -> Bool {
        suffixes.contains { suffix in
            let value = suffix.lowercased()
            return host == value || host.hasSuffix("." + value)
        }
    }

    /// 正则匹配：**包含**即算命中（参考实现用 `Matcher.find()`，不是整串匹配）。
    private static func matchesPattern(_ url: String, patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(url.startIndex ..< url.endIndex, in: url)
        return patterns.contains { $0.firstMatch(in: url, range: range) != nil }
    }

    // MARK: - 拼回清单

    /// 拼回清单：跳过被删片段与它前面的「边界标签」，并推进序列号。
    private static func render(
        _ nodes: [Node],
        trailingNewline: Bool,
        mediaSequenceIncrement: Int,
        discontinuitySequenceIncrement: Int
    ) throws -> String {
        var output = ""
        for (index, node) in nodes.enumerated() {
            if node.uri != nil, node.removed {
                continue
            }
            if node.uri == nil, isSegmentPrefix(node.leading.first ?? ""), prefixesRemovedSegment(nodes, from: index) {
                continue
            }
            for line in node.outputLines {
                output += try rewriteSequence(
                    line,
                    mediaIncrement: mediaSequenceIncrement,
                    discontinuityIncrement: discontinuitySequenceIncrement
                ) + "\n"
            }
        }
        // 输入末尾没有换行就还它没有换行（其余情况保持原样）。
        if !trailingNewline, !output.isEmpty {
            output.removeLast()
        }
        return output
    }

    /// 单行里的序列号推进；不是这两个标签就原样返回。
    private static func rewriteSequence(_ line: String, mediaIncrement: Int, discontinuityIncrement: Int) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if mediaIncrement > 0, trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
            return try incrementTag(line, tag: "#EXT-X-MEDIA-SEQUENCE:", increment: mediaIncrement)
        }
        if discontinuityIncrement > 0, trimmed.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
            return try incrementTag(line, tag: "#EXT-X-DISCONTINUITY-SEQUENCE:", increment: discontinuityIncrement)
        }
        return line
    }

    /// `#EXT-X-…-SEQUENCE:<值>` 加上 `increment`。拒绝负数、超 64 位与加完溢出（参考实现用 BigInteger 同样拦）。
    private static func incrementTag(_ line: String, tag: String, increment: Int) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let raw = trimmed.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
        guard !raw.hasPrefix("-"), let value = UInt64(raw) else {
            throw Failure.invalidSequence(raw)
        }
        let (updated, overflow) = value.addingReportingOverflow(UInt64(increment))
        guard !overflow else {
            throw Failure.invalidSequence(raw)
        }
        return tag + String(updated)
    }

    /// 「边界标签」：被删片段前面的这两行要一起丢掉（其余标签留着）。
    private static func isSegmentPrefix(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return value == "#EXT-X-DISCONTINUITY" || value.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
    }

    /// 这行边界标签后面（可跳过 `#EXT-X-KEY` / `#EXT-X-MAP` 这类「透明」标签）紧跟的第一个片段是不是被删了。
    private static func prefixesRemovedSegment(_ nodes: [Node], from index: Int) -> Bool {
        guard index + 1 < nodes.count else { return false }
        for next in nodes[(index + 1)...] {
            if next.uri != nil {
                return next.removed
            }
            let value = next.leading.first ?? ""
            if !isSegmentPrefix(value), !isTransparentStateTag(value) {
                return false
            }
        }
        return false
    }

    /// 「透明」标签：既不表示边界，也不影响该不该删（参考实现 `isTransparentStateTag`）。
    private static func isTransparentStateTag(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("#EXT-X-KEY:") || value.hasPrefix("#EXT-X-MAP:")
    }
}
