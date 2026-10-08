import Foundation

/// 一条 HLS 广告规则（JSON 形态：内置规则包、或接口配置里的那种）。
///
/// 逐条对齐参考实现 `app/src/main/java/com/fongmi/android/tv/bean/HlsAdRule.java`：
///
/// - `playlistHostSuffixes` / `playlistHostRegex` 是**作用域**（清单自己的 host 必须命中），至少给一个 ——
///   没有作用域的规则会命中所有站点，一律拒收；
/// - 其余字段是**信号**：`hostSuffixes`（分片 host 后缀）、`segmentUrlRegex`（分片 URL 正则）、
///   `minDuration` + `maxDuration`（时长区间）、`requireDiscontinuity`、`requireCrossDomain`；
/// - `minimumSignals` 必须落在 `1...信号数`：凑不够就是配错了，直接拒（而不是「按 1 算」）；
/// - `enabledByDefault` 是规则包作者的建议值，`enabled` 是**本地开关**（nil = 没设过）。
public struct HLSAdRule: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var version: Int
    /// 规则包作者建议的默认状态（内置规则默认关闭是硬要求，见 `docs/hls-rule-sources` 那套约定）。
    public var enabledByDefault: Bool
    public var playlistHostSuffixes: [String]
    public var playlistHostRegex: [String]
    public var hostSuffixes: [String]
    public var segmentUrlRegex: [String]
    public var minDuration: Double?
    public var maxDuration: Double?
    public var requireDiscontinuity: Bool
    public var requireCrossDomain: Bool
    public var minimumSignals: Int
    /// 本地开关（nil = 没设过 → 按 ``enabledByDefault``）。
    public var enabled: Bool?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenientString(.id)
        name = container.lenientString(.name)
        version = container.lenientInt(.version)
        enabledByDefault = container.lenientBool(.enabledByDefault)
        playlistHostSuffixes = container.lenientStringArray(.playlistHostSuffixes)
        playlistHostRegex = container.lenientStringArray(.playlistHostRegex)
        hostSuffixes = container.lenientStringArray(.hostSuffixes)
        segmentUrlRegex = container.lenientStringArray(.segmentUrlRegex)
        minDuration = container.lenientValue(.minDuration, as: Double.self)
        maxDuration = container.lenientValue(.maxDuration, as: Double.self)
        requireDiscontinuity = container.lenientBool(.requireDiscontinuity)
        requireCrossDomain = container.lenientBool(.requireCrossDomain)
        minimumSignals = container.lenientInt(.minimumSignals)
        enabled = container.lenientValue(.enabled, as: Bool.self)
    }

    /// 解析单条规则（坏 JSON / 缺字段都给 nil 语义的默认值，见 ``init(from:)``）。
    public static func parse(_ json: String) -> HLSAdRule? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HLSAdRule.self, from: data)
    }

    /// 解析一组规则（数组形态；坏 JSON 给空数组 —— 配错就当作没配）。
    public static func parseArray(_ json: String) -> [HLSAdRule] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([HLSAdRule].self, from: data)) ?? []
    }

    /// 这条规则一共给了几个信号（参考实现 `signalCount`）。
    public var signalCount: Int {
        var count = 0
        if !hostSuffixes.isEmpty {
            count += 1
        }
        if !segmentUrlRegex.isEmpty {
            count += 1
        }
        if minDuration != nil, maxDuration != nil {
            count += 1
        }
        if requireDiscontinuity {
            count += 1
        }
        if requireCrossDomain {
            count += 1
        }
        return count
    }

    /// 编成清理器认的规则。
    ///
    /// **不合法就抛**：调用方记日志并跳过这条，绝不「降级成更宽松的规则」——
    /// 广告清理的规则一旦放宽，误删的就是正常内容。
    public func compile() throws -> HLSManifestCleaner.Rule {
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HLSManifestCleaner.Failure.missingRuleID
        }
        guard Self.hasValues(playlistHostSuffixes) || Self.hasValues(playlistHostRegex) else {
            throw HLSManifestCleaner.Failure.missingPlaylistScope
        }
        if !hostSuffixes.isEmpty, !Self.hasValues(hostSuffixes) {
            throw HLSManifestCleaner.Failure.invalidSegmentHost
        }
        if segmentUrlRegex.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw HLSManifestCleaner.Failure.emptySegmentRegex
        }
        guard (minDuration == nil) == (maxDuration == nil) else {
            throw HLSManifestCleaner.Failure.incompleteDurationRange
        }
        var durationRange: ClosedRange<Double>?
        if let min = minDuration, let max = maxDuration {
            guard min.isFinite, max.isFinite, min >= 0, max >= min else {
                throw HLSManifestCleaner.Failure.invalidDurationRange
            }
            durationRange = min ... max
        }
        let signals = signalCount
        guard signals > 0, minimumSignals > 0, minimumSignals <= signals else {
            throw HLSManifestCleaner.Failure.invalidMinimumSignals
        }
        return try HLSManifestCleaner.Rule(
            id: id,
            hostSuffixes: hostSuffixes,
            playlistHostSuffixes: playlistHostSuffixes,
            playlistHostPatterns: playlistHostRegex,
            segmentUrlPatterns: segmentUrlRegex,
            durationRange: durationRange,
            requireDiscontinuity: requireDiscontinuity,
            requireCrossDomain: requireCrossDomain,
            minimumSignals: minimumSignals
        )
    }

    /// 数组里是不是每一项都非空（参考实现 `validStrings`）。
    static func hasValues(_ values: [String]) -> Bool {
        !values.isEmpty && values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case enabledByDefault
        case playlistHostSuffixes
        case playlistHostRegex
        case hostSuffixes
        case segmentUrlRegex
        case minDuration
        case maxDuration
        case requireDiscontinuity
        case requireCrossDomain
        case minimumSignals
        case enabled
    }
}
