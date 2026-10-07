import CatVodCore
import Testing

@Suite("type=4 聚合解析计划：对齐上游 ParseJob.superParse")
struct AggregateParsePlanTests {
    private func rule(_ name: String, type: ParserKind, url: String, flag: [String] = []) -> ParserRule {
        ParserRule(name: name, type: type.rawValue, url: url, ext: ParserExt(flag: flag))
    }

    private var allParsers: [ParserRule] {
        [
            rule("JSON 通用", type: .json, url: "https://j1.example.com/jx?url="),
            rule("Web 通用", type: .web, url: "https://w1.example.com/go?url="),
            rule("JSON 仅线路2", type: .json, url: "https://j2.example.com/jx?url=", flag: ["线路2"]),
            rule("JAR 忽略", type: .jarJson, url: "csp_Json"),
        ]
    }

    @Test("按 flag 分两组：只收 type=1 与 type=0，配置顺序不变")
    func grouping() {
        let plan = AggregateParsePlan(parsers: allParsers, flag: "线路1")
        #expect(plan.jsonParsers.map(\.name) == ["JSON 通用"])
        #expect(plan.webParsers.map(\.name) == ["Web 通用"])
        #expect(plan.taskCount == 2)
        #expect(plan.opensWebSniffer)
        #expect(!plan.isEmpty)
        #expect(plan.webSniffQuery == "https://w1.example.com/go?url=")
    }

    @Test("多个 type=0 合并成一次 Web 嗅探：taskCount 只加 1")
    func webOnly() {
        let parsers = [
            rule("Web1", type: .web, url: "https://w1.example.com/"),
            rule("Web2", type: .web, url: "https://w2.example.com/"),
        ]
        let plan = AggregateParsePlan(parsers: parsers, flag: "线路1")
        #expect(plan.jsonParsers.isEmpty)
        #expect(plan.taskCount == 1)
        #expect(plan.webSniffQuery == "https://w1.example.com/;https://w2.example.com/")
    }

    @Test("没有适用该线路的解析器时为空")
    func empty() {
        let onlyOtherLine = rule("仅线路2", type: .json, url: "https://j.example.com/jx?url=", flag: ["线路2"])
        let plan = AggregateParsePlan(parsers: [onlyOtherLine], flag: "线路1")
        #expect(plan.isEmpty)
        #expect(plan.taskCount == 0)
        #expect(!plan.opensWebSniffer)
        #expect(plan.jsonJobs(webURL: "https://cdn.example.com/x.m3u8").isEmpty)
    }

    @Test("成员任务：继承 webURL/header/click/flag，来源标成 aggregateMember")
    func jobs() {
        let plan = AggregateParsePlan(parsers: allParsers, flag: "线路1")
        let jobs = plan.jsonJobs(
            webURL: "https://cdn.example.com/x.m3u8",
            headers: ["Referer": "https://site.example.com/"],
            click: "click()",
            timeout: 9
        )
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .json)
        #expect(jobs[0].origin == .aggregateMember)
        #expect(jobs[0].origin.summary.contains("聚合"))
        #expect(jobs[0].webURL == "https://cdn.example.com/x.m3u8")
        #expect(jobs[0].flag == "线路1")
        #expect(jobs[0].headers["Referer"] == "https://site.example.com/")
        #expect(jobs[0].click == "click()")
        #expect(jobs[0].timeout == 9)
    }

    @Test("解析页：每个 type=0 一个 iframe")
    func parsePage() {
        let plan = AggregateParsePlan(parsers: allParsers, flag: "线路1")
        let html = plan.parsePageHTML(webURL: "https://cdn.example.com/x.m3u8?a=1")
        #expect(html.contains("const jxs = \"https://w1.example.com/go?url=\";"))
        #expect(html.contains("iframe.sandbox = 'allow-scripts allow-same-origin allow-forms';"))
        #expect(ParsePageHTML.frameCount(webParserURLs: plan.webSniffQuery) == 1)
        #expect(ParsePageHTML.frameCount(webParserURLs: "a;b;") == 2)
        #expect(ParsePageHTML.frameCount(webParserURLs: "") == 0)
    }

    @Test("解析页转义：引号与 `<` 不会写坏脚本，`</script>` 只出现一次")
    func parsePageEscaping() {
        let html = ParsePageHTML.page(
            webParserURLs: "https://w.example.com/</script>",
            webURL: "https://cdn.example.com/\"x\""
        )
        #expect(html.contains("const jxs = \"https://w.example.com/\\u003C/script>\";"))
        #expect(html.contains("const url = \"https://cdn.example.com/\\\"x\\\"\";"))
        #expect(html.components(separatedBy: "</script>").count - 1 == 1)
    }
}
