import CatVodCore
import Foundation
import Testing

@Suite("解析任务构造（对齐上游 ParseJob.setParse）")
struct ParseJobResolverTests {
    private let webURL = "https://cdn.example.com/a.m3u8"

    private func jsonParser(name: String = "解析A") -> ParserRule {
        ParserRule(name: name, type: ParserKind.json.rawValue, url: "https://p.example.com/jx?url=")
    }

    @Test("json: 前缀 → 临时 type=1 解析器（地址就是前缀后的内容）")
    func jsonPrefix() throws {
        let job = try ParseJobResolver.resolve(
            ParseContext(resultPlayURL: "json:https://jx.example.com/go?u=", webURL: webURL)
        )
        #expect(job.kind == .json)
        #expect(job.origin == .jsonPrefix)
        #expect(job.parser.url == "https://jx.example.com/go?u=")
        #expect(job.webURL == webURL)
        #expect(job.timeout == ParseJobResolver.defaultTimeout)
    }

    @Test("parse:名字 → 配置里的具名解析器（ext.header 优先、click 站点级优先）")
    func namedParser() throws {
        let rule = ParserRule(
            name: "解析B",
            type: ParserKind.json.rawValue,
            url: "https://p.example.com/jx?url=",
            ext: ParserExt(flag: ["线路1"], header: ["Referer": "https://p.example.com/"]),
            click: "resultClick"
        )
        let job = try ParseJobResolver.resolve(
            ParseContext(
                resultPlayURL: "parse:解析B",
                webURL: webURL,
                flag: "线路1",
                siteClick: "siteClick",
                resultClick: "resultClick",
                headers: ["User-Agent": "UA"],
                parsers: [rule]
            )
        )
        #expect(job.origin == .namedParser)
        #expect(job.parser.name == "解析B")
        #expect(job.acceptsFlag)
        // 解析器自带 ext.header 优先：结果的 User-Agent 不生效
        #expect(job.effectiveHeaders["Referer"] == "https://p.example.com/")
        #expect(job.effectiveHeaders["User-Agent"] == nil)
        // click：站点级优先，其次结果级
        #expect(job.click == "siteClick")
    }

    @Test("parse:名字 不存在 → parserNotFound（不学上游退化成无效 Web 页）")
    func missingNamedParser() {
        #expect(throws: ParseJobError.parserNotFound(name: "不存在")) {
            _ = try ParseJobResolver.resolve(ParseContext(resultPlayURL: "parse:不存在", webURL: webURL))
        }
    }

    @Test("结果级裸地址 → type=0 Web 解析页，地址就是这条裸地址")
    func bareAddress() throws {
        let job = try ParseJobResolver.resolve(
            ParseContext(resultPlayURL: "https://site.example.com/page", webURL: webURL)
        )
        #expect(job.kind == .web)
        #expect(job.origin == .webPage)
        #expect(job.parser.url == "https://site.example.com/page")
    }

    @Test("结果级为空 → 回退站点级前缀（本仓库既有约定）")
    func siteLevelFallback() throws {
        let job = try ParseJobResolver.resolve(
            ParseContext(
                sitePlayURL: "parse:站点解析",
                webURL: webURL,
                parsers: [jsonParser(name: "站点解析")]
            )
        )
        #expect(job.origin == .namedParser)
        #expect(job.parser.name == "站点解析")
    }

    @Test("useParse：json: 前缀覆盖默认解析器")
    func defaultParserOverriddenByPrefix() throws {
        let job = try ParseJobResolver.resolve(
            ParseContext(
                resultPlayURL: "json:https://jx.example.com/go?u=",
                webURL: webURL,
                parsers: [jsonParser(name: "默认")],
                defaultParserName: "默认",
                useParse: true
            )
        )
        #expect(job.origin == .jsonPrefix)
    }

    @Test("useParse：裸地址**不覆盖**默认解析器（上游的关键顺序）")
    func bareAddressKeepsDefaultParser() throws {
        let job = try ParseJobResolver.resolve(
            ParseContext(
                resultPlayURL: "https://site.example.com/page",
                webURL: webURL,
                parsers: [jsonParser(name: "默认")],
                defaultParserName: "默认",
                useParse: true
            )
        )
        #expect(job.origin == .defaultParser)
        #expect(job.parser.name == "默认")
    }

    @Test("webURL 为空 → emptyWebURL")
    func emptyWebURL() {
        #expect(throws: ParseJobError.emptyWebURL) {
            _ = try ParseJobResolver.resolve(ParseContext(resultPlayURL: "json:https://jx.example.com/"))
        }
    }

    @Test("JAR 解析器（type=2）→ parserUnavailable，原因里带解析器名")
    func jarUnavailable() {
        let rule = ParserRule(name: "JAR解析", type: ParserKind.jarJson.rawValue, url: "csp_Example")
        do {
            _ = try ParseJobResolver.resolve(
                ParseContext(resultPlayURL: "parse:JAR解析", webURL: webURL, parsers: [rule])
            )
            Issue.record("JAR 解析器应当被拒绝")
        } catch let error as ParseJobError {
            #expect(error.reason.contains("JAR解析"))
            #expect(error.reason.contains("JVM"))
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test("超时：默认 15 秒（对齐上游 TIMEOUT_PARSE_DEF），可被 context 覆盖")
    func timeout() throws {
        let custom = try ParseJobResolver.resolve(
            ParseContext(resultPlayURL: "json:https://jx.example.com/", webURL: webURL, timeout: 8)
        )
        #expect(custom.timeout == 8)

        let fallback = try ParseJobResolver.resolve(
            ParseContext(resultPlayURL: "json:https://jx.example.com/", webURL: webURL)
        )
        #expect(fallback.timeout == ParseJobResolver.defaultTimeout)
        #expect(ParseJobResolver.defaultTimeout == 15)
    }

    @Test("followUp：解析结果仍需解析 → 用默认解析器对解析结果再排队")
    func followUp() throws {
        let job = try ParseJobResolver.followUp(
            parsedURL: "https://cdn.example.com/real.m3u8",
            headers: ["Referer": "https://site.example.com/"],
            context: ParseContext(parsers: [jsonParser(name: "默认")], defaultParserName: "默认")
        )
        #expect(job.origin == .defaultParser)
        #expect(job.parser.name == "默认")
        #expect(job.webURL == "https://cdn.example.com/real.m3u8")
        #expect(job.effectiveHeaders["Referer"] == "https://site.example.com/")
    }

    @Test("没配默认解析器时 followUp 退化为 Web 嗅探页（type=0）")
    func followUpWithoutDefaultParser() throws {
        let job = try ParseJobResolver.followUp(
            parsedURL: "https://cdn.example.com/real.m3u8",
            headers: [:],
            context: ParseContext()
        )
        #expect(job.kind == .web)
        #expect(job.origin == .webPage)
        #expect(job.parser.url == "https://cdn.example.com/real.m3u8")
    }
}
