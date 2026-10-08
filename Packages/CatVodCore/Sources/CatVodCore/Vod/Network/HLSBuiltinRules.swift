import Foundation

/// 内置 HLS 广告规则包（资产 `Resources/hls_rules.json`；对应参考实现的 `BuiltinHlsRuleLoader` + `rules/hls_rules.json`）。
///
/// **当前规则集是空的 —— 而且是有意的。** 参考项目给内置规则定了几条门槛（见其 `docs/hls-rule-sources`）：
/// ①必须默认关闭；②要有「该删」与「不该删」两侧的 fixture 证据；③域名与广告时长会变，
/// 没有持续命中率 / 误杀率数据就不该默认开。没证据的规则不进内置集，所以这一版只落**路径与契约**：
/// 资产加载、`schemaVersion` 校验、进状态键的源标识。之后往 JSON 里加规则是改数据文件的事，不用动代码。
public enum HLSBuiltinRules {
    /// 资产名（`Resources/` 目录下）。
    static let assetName = "hls_rules"

    /// 内置包。读不到资产、坏 JSON、版本不认识 —— 一律当**空包**（内置规则出问题不该把播放路径拖下水）。
    public static let package: HLSAdRulePackage = load()

    /// 内置规则。
    public static var rules: [HLSAdRule] {
        package.rules
    }

    /// 进状态键的源标识：`包 id@版本`。
    ///
    /// 版本进键是有意的：规则 id 才是永久身份（上游规矩是**改条件只升 `version`、不改 id**），
    /// 所以开关跟着 id 走；包换了版本之后同一条规则的开关仍然有效，这正是想要的行为。
    public static var sourceID: String {
        let identifier = package.packageId.isEmpty ? "builtin" : package.packageId
        return "\(identifier)@\(package.version)"
    }

    /// 资产文本；读不到返回 nil（调用方降解成空包）。
    private static func assetText() -> String? {
        let url = Bundle.module.url(forResource: assetName, withExtension: "json", subdirectory: "Resources")
        guard let url else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func load() -> HLSAdRulePackage {
        guard let text = assetText() else {
            return .empty
        }
        return HLSAdRulePackage.parse(text)
    }
}
