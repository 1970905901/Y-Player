import CatVodCore
import Testing

@Suite("嗅探规则引擎：对齐上游 Sniffer")
struct SniffRulesTests {
    private func engine(_ items: [SniffRule] = [], ads: [String] = []) -> SniffRules {
        SniffRules(rules: items, ads: ads)
    }

    private var siteRule: SniffRule {
        SniffRule(
            name: "示例站",
            hosts: ["example.com"],
            regex: ["/videos/"],
            exclude: ["/ads/"],
            script: ["document.querySelector('button').click()"]
        )
    }

    @Test("host 匹配文本 = URL host + `url` 查询参数里的 host")
    func hostMatchText() {
        #expect(SniffRules.hostMatchText(for: "https://cdn.example.com/a.m3u8") == "cdn.example.com")
        let wrapped = "https://jx.example.com/go?url=https%3A%2F%2Fcdn.example.com%2Fa.m3u8"
        #expect(SniffRules.hostMatchText(for: wrapped) == "jx.example.com,cdn.example.com")
        #expect(SniffRules.hostMatchText(for: "not a url") == "")
    }

    @Test("规则命中：hosts 按 containOrMatch 匹配，取第一条")
    func ruleMatching() {
        let rules = engine([siteRule, SniffRule(name: "兜底", hosts: ["*"])])
        #expect(rules.rule(forURL: "https://cdn.example.com/x.mp4")?.name == "示例站")
        #expect(rules.rule(forURL: "https://other.example.net/x.mp4")?.name == "兜底")
        #expect(engine([siteRule]).rule(forURL: "https://other.example.net/x.mp4") == nil)
    }

    @Test("规则命中：URL 里 `url=` 指向的 host 也算（上游把两个 host 拼起来匹配）")
    func ruleMatchingThroughQuery() {
        let wrapped = "https://jx.other.net/go?url=https://api.example.com/x"
        #expect(engine([siteRule]).rule(forURL: wrapped)?.name == "示例站")
    }

    @Test("exclude 优先于 regex：带 `/ads/` 的地址判为不是媒体")
    func excludeWins() {
        let decision = engine([siteRule]).decision(forURL: "https://cdn.example.com/ads/clip.m3u8")
        #expect(decision == .ruleExcluded(rule: "示例站", pattern: "/ads/"))
        #expect(!decision.isMedia)
    }

    @Test("regex 命中即媒体：没有扩展名也能靠规则认出")
    func regexMatches() {
        let decision = engine([siteRule]).decision(forURL: "https://cdn.example.com/videos/12345")
        #expect(decision == .ruleMatched(rule: "示例站", pattern: "/videos/"))
        #expect(decision.isMedia)
    }

    @Test("默认媒体正则：扩展名、`video/tos`、`rtmp` 三种形态")
    func defaultPattern() {
        let rules = engine()
        #expect(rules.decision(forURL: "https://cdn.example.com/live/abc.m3u8?token=1") == .defaultPatternMatched)
        #expect(rules.isVideoFormat("https://v.example.com/video/tos/xyz/play"))
        #expect(rules.isVideoFormat("rtmp://live.example.com/app/stream"))
        #expect(!rules.isVideoFormat("https://cdn.example.com/page.html"))
        #expect(!rules.isVideoFormat("https://cdn.example.com/go?url=http://x/y.mp4"))
        let notMedia = "不匹配默认媒体正则（m3u8/mp4/mkv/flv/mp3/m4a/aac/mpd、video/tos、rtmp）"
        #expect(rules.decision(forURL: "https://cdn.example.com/x.jpg") == .notMediaFormat(reason: notMedia))
    }

    @Test("页面脚本：取命中规则的 script")
    func scripts() {
        #expect(engine([siteRule]).scripts(forURL: "https://cdn.example.com/x") == ["document.querySelector('button').click()"])
        #expect(engine([siteRule]).scripts(forURL: "https://other.example.net/x").isEmpty)
    }

    @Test("广告判定：ads 里任一命中即算广告")
    func ads() {
        let rules = engine(ads: ["ads.example.com", "^ad\\d+\\.net$"])
        #expect(rules.isAd(host: "cdn.ads.example.com"))
        #expect(rules.isAd(host: "ad7.net"))
        #expect(!rules.isAd(host: "cdn.example.com"))
        #expect(engine(ads: ["*"]).isAd(host: "anything.example.com"))
    }

    @Test("`player.*https?://` 命中说明要再开一层嗅探")
    func playerPage() {
        #expect(SniffRules.isPlayerPage("https://cdn.example.com/player/?url=https://x/y.mp4"))
        #expect(!SniffRules.isPlayerPage("https://cdn.example.com/x.mp4"))
    }

    @Test("文本抽取：JSON 对象与含 `$` 的内容原样返回，否则抽 AI_PUSH")
    func textExtraction() {
        let json = #"{"url":"https://cdn.example.com/a.m3u8"}"#
        #expect(SniffRules.mediaURL(inText: json) == json)
        let dollar = "价格 $9 的 https://cdn.example.com/a.m3u8"
        #expect(SniffRules.mediaURL(inText: dollar) == dollar)
        #expect(SniffRules.mediaURL(inText: "下载 thunder://QUFodHRwOi8v 提取码 1234") == "thunder://QUFodHRwOi8v")
        #expect(SniffRules.mediaURL(inText: "没有链接") == "没有链接")
        let html = "<video src=\"https://cdn.example.com/live/a.m3u8?x=1\"></video>"
        #expect(SniffRules.firstMediaURL(inText: html) == "https://cdn.example.com/live/a.m3u8?x=1")
        #expect(SniffRules.firstMediaURL(inText: "<html></html>") == nil)
    }
}
