@testable import CatVodCore
import Foundation
import Testing

/// 分组规则的抽取语义：**逐条对齐上游 `GroupRuleTest`**（那 12 条就是它的行为规格）。
///
/// 抽标签是「站点面板分组条」的全部依据，所以每条内置规则、AI 安全子集、坏正则都单独钉。
@Suite("站点分组规则（对齐 GroupRuleTest）")
struct GroupRuleTests {
    @Test("方括号标签：一段名字里出现的都要抽出来")
    func bracketBuiltinExtractsTags() {
        let rule = GroupRule.builtin(
            id: GroupRuleConfig.builtinBracket,
            name: "方括号标签",
            regex: "\\[([^\\]]+)\\]"
        )

        #expect(rule.extract("[主力][短剧]我的站") == ["主力", "短剧"])
    }

    @Test("竖线后缀：只取最后一段（半角与全角竖线都算）")
    func pipeBuiltinExtractsSuffixAfterPipe() {
        let rule = GroupRule.builtin(
            id: GroupRuleConfig.builtinPipe,
            name: "竖线后缀",
            regex: "(?i)(?:[|｜])\\s*([^|｜]+?)\\s*$"
        )

        #expect(rule.extract("⭐夏天|秒播") == ["秒播"])
        #expect(rule.extract("💥木偶|4K") == ["4K"])
        #expect(rule.extract("💥玩偶|4K") == ["4K"])
        #expect(rule.extract("某某｜1080P") == ["1080P"])
        #expect(rule.extract("普通线路").isEmpty)
    }

    @Test("框线分隔：取 `┆` 后的最后一段")
    func boxBuiltinExtractsLastSegment() {
        let rule = GroupRule.builtin(
            id: GroupRuleConfig.builtinBox,
            name: "框线分隔",
            regex: "(?i)┆\\s*([^┆]+)\\s*$"
        )

        #expect(rule.extract("👽️┆玩偶┆4K") == ["4K"])
        #expect(rule.extract("🪵┆木偶┆4K") == ["4K"])
        #expect(rule.extract("来源┆蓝光") == ["蓝光"])
    }

    @Test("圆点后缀：`•` 与 `·` 都算")
    func bulletBuiltinExtractsSuffixAfterBullet() {
        let rule = GroupRule.builtin(
            id: GroupRuleConfig.builtinBullet,
            name: "圆点后缀",
            regex: "(?i)(?:[•·])\\s*([^•·]+?)\\s*$"
        )

        #expect(rule.extract("热播 • APP") == ["APP"])
        #expect(rule.extract("蜡笔 • 4K") == ["4K"])
        #expect(rule.extract("热播·APP") == ["APP"])
        #expect(rule.extract("普通线路").isEmpty)
    }

    @Test("四条内置规则默认启用且都编得出来")
    func builtinsAreEnabledByDefault() {
        for rule in GroupRuleConfig.builtins {
            #expect(rule.enabled, "\(rule.id)")
            #expect(rule.isValid, "\(rule.id)")
            #expect(rule.source == GroupRule.sourceBuiltin)
        }
    }

    @Test("自定义规则用第 1 个捕获组")
    func customRuleUsesFirstCaptureGroup() {
        let rule = GroupRule.user(name: "自定义", regex: "(?i)【(.+?)】")

        #expect(rule.isValid)
        #expect(rule.extract("电影【HDR】") == ["HDR"])
    }

    @Test("坏正则：判为不可用，且抽不出任何东西（不抛、不崩）")
    func invalidRegexIsRejected() {
        let rule = GroupRule.user(name: "坏规则", regex: "(")

        #expect(!rule.isValid)
        #expect(rule.extract("任意文本").isEmpty)
    }

    @Test("接口配置给的规则：缺的字段按上游补默认值，且 id 稳定")
    func interfaceArrayFillsDefaults() throws {
        let json = """
        [{"name":"接口规则","regex":"#(.+)$"}]
        """
        let rules = try JSONDecoder().decode([GroupRule].self, from: Data(json.utf8))

        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(!rule.id.isEmpty)
        #expect(rule.source == GroupRule.sourceInterface)
        #expect(rule.enabled)
        #expect(rule.extract("前缀#分组A") == ["分组A"])
        // 稳定 id：同一份配置每次解出来都一样（上游随机 UUID，那样按 id 存的开关会失配）
        let again = try JSONDecoder().decode([GroupRule].self, from: Data(json.utf8))
        #expect(rule.id == again.first?.id)
    }

    @Test("`wrapBracket`：抽出来的标签套成 `[标签]`，已经是方括号的不重复套")
    func wrapBracketWrapsTags() {
        let piped = GroupRule.user(name: "竖线", regex: "(?i)(?:[|｜])\\s*([^|｜]+?)\\s*$", wrapBracket: true)
        // 捕获组本身就是 `[主力]` 这种形状时不要再套一层
        let bracketed = GroupRule.user(name: "整段方括号", regex: "(\\[[^\\]]+\\])", wrapBracket: true)

        #expect(piped.extract("木偶|4K") == ["[4K]"])
        #expect(bracketed.extract("[主力]站") == ["[主力]"])
    }

    @Test("AI 规则只接受线性安全子集")
    func aiRuleAcceptsOnlySafeLinearRegex() {
        #expect(GroupRule.ai(name: "方括号", regex: "\\[([^\\]]+)\\]").isValid)
        #expect(GroupRule.ai(name: "竖线", regex: "(?i)(?:[|｜])\\s*([^|｜]+?)\\s*$").isValid)
        #expect(GroupRule.ai(name: "框线", regex: "(?i)┆\\s*([^┆]+)\\s*$").isValid)
        #expect(GroupRule.ai(name: "圆点", regex: "(?i)(?:[•·])\\s*([^•·]+?)\\s*$").isValid)
        #expect(GroupRule.ai(name: "前缀", regex: "^([^:：]+)[:：]").isValid)
    }

    @Test("AI 规则拒绝会回溯爆炸的写法")
    func aiRuleRejectsBacktrackingProneRegex() {
        #expect(!GroupRule.ai(name: "交替回溯", regex: "^(a|aa)+$").isValid)
        #expect(!GroupRule.ai(name: "重复分组", regex: "^(\\w+\\s?)*$").isValid)
        #expect(!GroupRule.ai(name: "任意通配", regex: "^(.+)$").isValid)
        #expect(!GroupRule.ai(name: "回溯引用", regex: "^(a+)\\1$").isValid)
        #expect(!GroupRule.ai(name: "多段回溯", regex: "^(a*a*a*b)$").isValid)
    }

    @Test("AI 规则不拿去跑超长文本（站点名几 KB 那种）")
    func aiRuleSkipsOverlongText() {
        let rule = GroupRule.ai(name: "前缀", regex: "^([^:：]+)[:：]")

        #expect(rule.extract(String(repeating: "a", count: 300) + ":短剧").isEmpty)
    }

    @Test("用户规则不受 AI 安全子集限制（上游同样只卡 AI）")
    func userRuleAllowsAdvancedRegex() {
        #expect(GroupRule.user(name: "用户自定义", regex: "^(a|aa)+$").isValid)
    }
}
