import Foundation

/// XMLTV（`<tv><channel/><programme/></tv>`）→ ``EPGGuide``。
///
/// 对齐上游 `EpgParser.parseXml` 的语义：
/// - `<programme start="20261007190000 +0800" stop="…" channel="cctv1"><title>…</title>` 的时间串
///   交给 ``EPGTimeParser/parseFull(_:timeZone:)``（带时区用 `+0800` / `+08:00`，不带则按直播源时区解释）；
/// - `<channel id="…"><display-name>…</display-name></channel>` 收进 ``EPGGuide/channelNames``
///   （上游用它把频道显示成 EPG 里的名字）；
/// - 节目按「频道 + 源时区下的日期」切进 ``EPGSchedule``，**并当场算好绝对时间**：
///   `HH:mm` 展示串与 `startTime`/`endTime` 出自同一套时区，所以之后再 `normalized(timeZone:)` 结果不变。
///
/// 两处真实世界的兼容（上游没有，但抓到的 XMLTV 里见过，见 `docs/任务记录/M07b-EPG拉取与XMLTV解析.md`）：
/// 1. `20261007T190000+0800` / `…Z` / `…+08:00` 这些写法先规整成上游 `EPG_FULL` 认的 `20261007190000 +0800`；
/// 2. `stop` 缺失或解析不出来时，**结束时间取开始时间**（显示成零长度，而不是 1970 年）。
///
/// 明确不做：繁简转换（上游 `Trans.s2t`）、`<programme>` 里除 `title` 之外的元数据
/// （`<desc>`/`<icon>`/`<rating>`）、`stop` 缺失时按「下一档开始时间」推断（上游也不推断）。
/// `<channel>` 的 `<icon src>` **会收**（上游拿它做频道图标回填，M07c）。
public enum EPGXMLTVParser {
    /// 解析 XMLTV；不是 XML 或没有 `<tv>` 时返回 `nil`（调用方按「这个地址没有可用节目单」处理）。
    public static func parse(data: Data, timeZone: TimeZone) -> EPGGuide? {
        let delegate = XMLTVDelegate(timeZone: timeZone)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), delegate.sawTV else {
            return nil
        }
        return delegate.guide()
    }

    /// 解析**单个频道**的 XMLTV（x-tvg 接口形态，M07c）。
    ///
    /// 上游 `LiveApi.fetchEpgDay` 把接口返回的节目单挂在**直播频道的 `epgID`** 上
    /// （`Epg.objectFrom(body, item.getTvgId(), zoneId)`），而不是 `<programme channel="…">`
    /// 自己的 id：接口常按频道名拉取，返回的 id 与清单里的 `tvg-id` 对不上。
    /// 所以这里把切片键统一改写成 `key`（``EPGGuide/rekeyed(to:)``），
    /// 并丢掉 `<channel>` 里的名称/图标 —— 接口形态下界面用清单里的名字与图标（与上游一致）。
    public static func parse(data: Data, key: String, timeZone: TimeZone) -> EPGGuide? {
        guard let parsed = parse(data: data, timeZone: timeZone) else {
            return nil
        }
        return parsed.rekeyed(to: key)
    }

    /// 把时间串规整成 ``EPGTimeParser/parseFull(_:timeZone:)`` 认的 `yyyyMMddHHmmss ±HHMM`：
    ///
    /// | 原始 | 规整后 |
    /// | --- | --- |
    /// | `20261007T190000+0800` | `20261007190000 +0800` |
    /// | `20261007190000+08:00` | `20261007190000 +08:00` |
    /// | `20261007190000Z` | `20261007190000 +0000`（`Z` 是 UTC，不能当源时区） |
    /// | `20261007190000 +0800` | 原样（已经有分隔空格） |
    /// | `20261007190000` | 原样（没有时区，按源时区解释） |
    static func normalizedTime(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "T", with: "")
        if text.hasSuffix("Z") {
            text = String(text.dropLast()) + "+0000"
        }
        return insertingZoneSeparator(text)
    }

    /// 末尾的 `±HHMM` / `±HH:MM` 前补一个空格（`parseFull` 靠长度与空格区分「带时区」分支）。
    private static func insertingZoneSeparator(_ text: String) -> String {
        // 先试 `±HHMM`（5 个字符）再试 `±HH:MM`（6 个）；前段必须是紧凑日期串，
        // 否则像 `2026-10-07` 这种会把 `-10-07` 误判成时区。
        for length in [5, 6] {
            guard text.count >= 14 + length else {
                continue
            }
            let suffix = String(text.suffix(length))
            guard suffix.hasPrefix("+") || suffix.hasPrefix("-") else {
                continue
            }
            let digits = suffix.dropFirst().filter { $0.isNumber }
            guard digits.count == 4 else {
                continue
            }
            let head = String(text.dropLast(length))
            guard head.count >= 14, head.allSatisfy({ $0.isNumber }) else {
                continue
            }
            return head.hasSuffix(" ") ? text : head + " " + suffix
        }
        return text
    }
}

/// XMLTV 的解析状态机（只关心 `<channel>` 的显示名与 `<programme>` 的时间/标题）。
private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    /// 解析期临时持有的原始节目（时间串还没变成 `Date`）。
    private struct RawProgramme {
        var channel = ""
        var start = ""
        var stop = ""
        var title = ""
    }

    private let timeZone: TimeZone
    private var names: [String: String] = [:]
    /// `<channel id="…"><icon src="…"></channel>` 的图标（上游 `Tv.Channel.getSrc()`）。
    private var logos: [String: String] = [:]
    private var programmes: [RawProgramme] = []
    private var currentChannelID = ""
    private var currentProgramme: RawProgramme?
    private var text = ""
    /// 文件里出现过 `<tv>` 才算 XMLTV（否则 `parse` 返回 `nil`，让调用方明确报错）。
    private(set) var sawTV = false

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: - 收集

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "tv":
            sawTV = true
        case "channel":
            currentChannelID = attributeDict["id"] ?? ""
        case "programme":
            currentProgramme = RawProgramme(
                channel: attributeDict["channel"] ?? currentChannelID,
                start: attributeDict["start"] ?? "",
                stop: attributeDict["stop"] ?? ""
            )
        case "icon":
            // 只认 `<channel>` 里的图标；`<programme>` 里的 `<icon>` 是剧照，不做频道图标用。
            if currentProgramme == nil, !currentChannelID.isEmpty, let src = attributeDict["src"], !src.isEmpty {
                logos[currentChannelID] = src
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        switch elementName {
        case "display-name":
            // 只认 `<channel>` 里的 display-name（`<programme>` 里没有这个元素）。
            if currentProgramme == nil, !currentChannelID.isEmpty, !value.isEmpty {
                names[currentChannelID] = value
            }
        case "title":
            if var programme = currentProgramme {
                programme.title = value
                currentProgramme = programme
            }
        case "channel":
            currentChannelID = ""
        case "programme":
            if let programme = currentProgramme {
                programmes.append(programme)
            }
            currentProgramme = nil
        default:
            break
        }
    }

    // MARK: - 归集

    /// 原始节目 → ``EPGGuide``：按「频道 + 源时区日期」切片、排序，丢掉没有标题或时间解析失败的条目。
    func guide() -> EPGGuide {
        var slices: [EPGSchedule] = []
        var indexByID: [String: Int] = [:]
        for raw in programmes where !raw.channel.isEmpty {
            let start = EPGTimeParser.parseFull(EPGXMLTVParser.normalizedTime(raw.start), timeZone: timeZone)
            // 时间解析失败会退化成 epoch（`EPGTimeParser` 的约定），这种条目直接丢掉：
            // 留着只会在界面上显示成 1970 年。
            guard start.timeIntervalSince1970 > 0, !raw.title.isEmpty else {
                continue
            }
            let stop = EPGTimeParser.parseFull(EPGXMLTVParser.normalizedTime(raw.stop), timeZone: timeZone)
            let end = stop.timeIntervalSince1970 > 0 ? stop : start
            let date = EPGTimeParser.formatDate(start, timeZone: timeZone)
            let id = raw.channel + "@" + date
            let program = EPGProgram(
                title: raw.title,
                start: EPGTimeParser.formatTime(start, timeZone: timeZone),
                end: EPGTimeParser.formatTime(end, timeZone: timeZone),
                startTime: start,
                endTime: end
            )
            if let index = indexByID[id] {
                slices[index].programs.append(program)
            } else {
                indexByID[id] = slices.count
                slices.append(EPGSchedule(key: raw.channel, date: date, programs: [program]))
            }
        }
        for index in slices.indices {
            // 同一开始时间的按标题排：`sort` 不保证稳定，加二级键让结果可预期。
            slices[index].programs.sort { ($0.startTime, $0.title) < ($1.startTime, $1.title) }
        }
        return EPGGuide(timeZone: timeZone, channelNames: names, channelLogos: logos, schedules: slices)
    }
}
