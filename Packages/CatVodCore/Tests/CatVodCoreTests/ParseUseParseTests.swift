import CatVodCore
import Testing

/// `ParseResultValidator.usesParse`：上游 `Result.isUseParse()`（M09h）。
///
/// 为什么要单独钉它：这是**两个极易混淆的判定**里的第二个 ——
/// `needParse()`（结果自称要解析）与 `isUseParse()`（配置认不认这条线路要解析）在代码里只差几个字，
/// 混用不会崩、只会「某些线路的解析莫名其妙不生效」，真机上极难查。
///
/// 顺带：配置的 `flags`（上游 `vipFlags`）**唯一**的用途就是这里。
@Suite("解析判定：要不要套默认解析器（isUseParse）")
struct ParseUseParseTests {
    private func usesParse(
        playURL: String = "",
        flag: String = "youku",
        flags: [String] = ["youku"],
        hasDefaultParser: Bool = true,
        jx: Int = 0
    ) -> Bool {
        ParseResultValidator.usesParse(
            resultPlayURL: playURL,
            flag: flag,
            configFlags: flags,
            hasDefaultParser: hasDefaultParser,
            jx: jx
        )
    }

    @Test("结果没有 playUrl、线路被配置声明、配置又有默认解析器 → 要解析")
    func declaredFlagWithoutPlayURLUsesParse() {
        #expect(usesParse())
    }

    @Test("线路没被配置声明 → 不解析（哪怕 playUrl 是空的）")
    func undeclaredFlagDoesNotUseParse() {
        #expect(!usesParse(flag: "qq"))
        #expect(!usesParse(flags: []))
    }

    @Test("结果自带 playUrl（`json:` / `parse:` 前缀那条路）→ 这一步不接管")
    func nonEmptyPlayURLDoesNotUseParse() {
        #expect(!usesParse(playURL: "json:https://api.example/parse"))
    }

    @Test("`jx = 1` 一律要解析，与线路声明无关")
    func jxAlwaysUsesParse() {
        #expect(usesParse(flag: "qq", flags: [], jx: 1))
        #expect(usesParse(playURL: "json:https://api.example/parse", flag: "qq", flags: [], jx: 1))
    }

    @Test("配置里没有默认解析器 → 一律不解析，连 `jx = 1` 也一样（上游就是这个顺序）")
    func withoutDefaultParserNothingUsesParse() {
        #expect(!usesParse(hasDefaultParser: false))
        // 参数顺序按声明来（`hasDefaultParser` 在 `jx` 前）——顺序错了是编译错误。
        #expect(!usesParse(hasDefaultParser: false, jx: 1))
    }

    @Test("空线路名不匹配任何 flag：别把「没有线路名的直链结果」判成要解析")
    func emptyFlagNeverMatches() {
        #expect(!usesParse(flag: "", flags: ["", "youku"]))
        #expect(!usesParse(flag: "   ", flags: ["   "]))
    }

    @Test("与 `needParse()` 各管各的：结果自称要解析，但线路没被声明、`jx = 0` → 这一步不接管")
    func differsFromNeedParse() {
        var result = SpiderResult()
        result.parse = 1
        result.jx = 0
        result.playUrl = "parse:默认解析器"

        // 结果自称要解析（`needParse()` / `requiresParsing` 为 true）……
        #expect(ParseResultValidator.needsFollowUp(result))
        // ……但从「配置要不要先套默认解析器」的角度看，这条线路没被 `flags` 声明，不接管。
        // 这两件事混用，就是 M09h 之前的状态：`flags` 一直没有消费方。
        #expect(!usesParse(playURL: result.playUrl, flag: "qq", flags: []))
    }
}
