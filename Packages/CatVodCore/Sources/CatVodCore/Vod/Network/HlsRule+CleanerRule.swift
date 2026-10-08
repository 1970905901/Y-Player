import Foundation

// 接口配置里的 `hlsRules`（``HlsRule``：`hosts` / `regex` / `exclude`）→ 广告清理器认的规则。
//
// 对齐参考实现 `api/config/HlsRuleConfig.java#compileLegacyRules`：
// - `hosts` → **清单作用域正则**（`playlistHostPatterns`）；
// - `exclude` → **分片 URL 正则**（`segmentUrlPatterns`），也就是「广告地址特征」；
// - `regex` 不参与（参考实现那一份也只用 `hosts` + `exclude`）；
// - `exclude` 为空整条跳过：没有可匹配的分片特征，留着只会变成「命中一切」的空规则。
//
// 为什么放 Core：这是「配置 → 清理规则」的纯换算，与界面无关，和清理器在同一层，测试也不需要起服务。
public extension HlsRule {
    /// 编成清理器的规则；`exclude` 为空时返回 nil（调用方跳过这条）。
    func compiledAdRule() -> HLSManifestCleaner.Rule? {
        guard !exclude.isEmpty else { return nil }
        return try? HLSManifestCleaner.Rule(
            id: cleanerRuleID,
            playlistHostPatterns: hosts,
            segmentUrlPatterns: exclude,
            minimumSignals: 1
        )
    }

    /// 规则 id：`legacy:` + 三个字段的摘要。
    ///
    /// 参考实现用 `legacy:` + `RuleIdUtil.computeRuleId(rule)`；我们同样取摘要 ——
    /// 同一份配置每次算出来都一样，「删了几段」的统计才对得上、日志里也认得出是哪条配置规则。
    var cleanerRuleID: String {
        let seed = hosts.joined(separator: ",") + "|"
            + regex.joined(separator: ",") + "|"
            + exclude.joined(separator: ",")
        return "legacy:" + String(MD5.hexDigest(of: seed).prefix(16))
    }
}
