import CatVodCore
import CatVodNet
import Foundation

/// EPG 加载：取节目单 → ``EPGXMLTVParser`` / ``EPGJSONParser`` → 合并成一个 ``EPGGuide``。
///
/// 两条通路，对应上游两处入口：
/// 1. **文件**（``load(_:)``，上游 `LiveApi.parseXml` + `EpgParser.start`）：`epg` 里 `.xml` / `.gz`
///    那些地址，逐个拉取后合并 —— 一个源可以配多个（例如「央视.xml,卫视.xml.gz」）；
/// 2. **接口**（``load(channel:source:existing:dayOffsets:)``，上游 `LiveApi.getEpg` + `fetchEpgDay`）：
///    `epg` 里含 `{…}` 的那一项，按**频道 × 天**请求，返回 XMLTV 或 JSON（M07c）。
///
/// 两条通路共用的约定：
/// - 请求带源级 ``LiveSource/headers()`` 与 ``LiveSource/timeout``（与 ``LiveRepository`` 同一套）；
/// - `.gz` 按**魔数**识别并解压（见 ``GZipDecoder``），不信地址扩展名；
/// - 非 2xx、地址非法、不是节目单、解压失败一律抛 ``CatVodError``，**全失败才算失败**
///   （部分地址/部分天坏不影响已经拿到的节目单）。
public struct LiveEPGRepository: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 拉取并解析一个直播源的**节目单文件**（`epg` 里的 `.xml` / `.gz`）。
    public func load(_ source: LiveSource) async throws -> EPGGuide {
        try await load(source, fileURLs: source.epgXML)
    }

    /// 同上，但地址由调用方给全（**本地 EPG 覆盖**走这条，见 ``LiveEPGOverride``）。
    ///
    /// 为什么要单独给一份：覆盖地址可能不带 `xml` / `gz` 字样（例如 `…/epg.php`），
    /// 过不了 ``LiveSource/epgXML`` 的过滤，得由 ``LiveEPGOverride/fileURLs(for:)`` 算出来。
    public func load(_ source: LiveSource, fileURLs: [String]) async throws -> EPGGuide {
        let entries = fileURLs
        guard !entries.isEmpty else {
            throw CatVodError.unsupported(
                feature: "直播源「\(source.name)」的节目单",
                reason: source.epg.isEmpty
                    ? "epg 字段为空"
                    : "只配了 x-tvg 接口（含 `{…}`）—— 用 load(channel:source:existing:) 逐频道拉"
            )
        }
        let timeZone = EPGTimeParser.timeZone(named: source.timeZone)
        var guide = EPGGuide(timeZone: timeZone)
        var firstError: CatVodError?
        for entry in entries {
            do {
                let data = try await fetchData(entry, source: source)
                guard let parsed = EPGXMLTVParser.parse(data: data, timeZone: timeZone) else {
                    throw CatVodError.parseFailed(
                        flag: source.name,
                        reason: "节目单不是 XMLTV：\(String(entry.prefix(120)))"
                    )
                }
                guide = guide.merging(parsed)
            } catch let error as CatVodError {
                // 记下第一个错误：地址可能配了多个，全都拿不到才把错误抛给界面。
                if firstError == nil {
                    firstError = error
                }
            } catch {
                // 传输层已把底层错误统一包成 `CatVodError`（M6 请求管线），这里兜住漏网的实现：
                // 格式上必须是裸 `catch`（SwiftFormat `redundantLetError`；与 `URLSessionTransport` 同一写法）。
                if firstError == nil {
                    firstError = CatVodError.parseFailed(
                        flag: source.name,
                        reason: "节目单拉取失败：\(String(entry.prefix(120))) — \(error)"
                    )
                }
            }
        }
        guard !guide.isEmpty else {
            throw firstError ?? CatVodError.parseFailed(flag: source.name, reason: "节目单没有可用内容")
        }
        return guide
    }

    /// 拉取一个频道的节目单（**x-tvg 接口**形态：逐频道 × 昨天/今天/明天）。
    ///
    /// 对齐上游 `LiveApi.getEpg(_:zoneId:)` + `fetchEpgDay(_:zoneId:offset:)`：
    /// - 日期按**直播源时区**算（``EPGTimeParser/dateString(dayOffset:timeZone:)``），只替换模板里的 `{date}` ——
    ///   `{id}`/`{name}`/`{epg}` 在频道生成时就已经展开（``LiveChannel/inherit(from:)``）；
    /// - 地址必须是 `http` 开头（上游 `url.startsWith("http")`），否则这一天的节目单拿不到，只记一笔；
    /// - `existing` 里已有这个频道这一天的切片就**跳过请求**（上游 `noneMatch(epg -> epg.equal(date))`），
    ///   界面把上次的 guide 原样传回来即可增量刷新；
    /// - 单天失败不影响其它天（上游 `fetchEpgDay` 吞异常），**一天都没成功**才抛错。
    public func load(
        channel: LiveChannel,
        source: LiveSource,
        existing: EPGGuide? = nil,
        dayOffsets: [Int] = [-1, 0, 1]
    ) async throws -> EPGGuide {
        let timeZone = existing?.timeZone ?? EPGTimeParser.timeZone(named: source.timeZone)
        let key = channel.epgID
        guard !channel.epg.isEmpty, !key.isEmpty else {
            throw CatVodError.unsupported(
                feature: "频道「\(channel.name)」的节目单",
                reason: "频道没有可用的节目单地址（清单里没有，源级 epg 里也没有可展开的接口模板）"
            )
        }
        var guide = existing ?? EPGGuide(timeZone: timeZone)
        var firstError: CatVodError?
        var loaded = false
        for offset in dayOffsets {
            let date = EPGTimeParser.dateString(dayOffset: offset, timeZone: timeZone)
            if guide.contains(key: key, date: date) {
                // 已经有这一天：不发请求，但也算「拿得到节目单」。
                loaded = true
                continue
            }
            let url = percentEncoded(channel.epg.replacingOccurrences(of: "{date}", with: date))
            guard url.hasPrefix("http") else {
                firstError = firstError ?? CatVodError.unsupported(
                    feature: "频道「\(channel.name)」的节目单",
                    reason: "节目单地址不是 http（上游同样跳过）：\(String(url.prefix(120)))"
                )
                continue
            }
            do {
                let slice = try await loadDay(url: url, key: key, timeZone: timeZone, source: source, channel: channel)
                guide = guide.merging(slice)
                loaded = true
            } catch let error as CatVodError {
                firstError = firstError ?? error
            } catch {
                firstError = firstError ?? CatVodError.parseFailed(
                    flag: channel.name,
                    reason: "节目单拉取失败：\(String(url.prefix(120))) — \(error)"
                )
            }
        }
        guard loaded else {
            throw firstError ?? CatVodError.parseFailed(flag: channel.name, reason: "节目单没有可用内容")
        }
        return guide
    }

    /// 拉并解析**一天**：JSON 对象形态交 ``EPGJSONParser``，其余按 XMLTV（上游 `Epg.objectFrom` 的判断顺序）。
    private func loadDay(
        url: String,
        key: String,
        timeZone: TimeZone,
        source: LiveSource,
        channel: LiveChannel
    ) async throws -> EPGGuide {
        let data = try await fetchData(url, source: source)
        if let schedule = EPGJSONParser.parse(data: data, key: key, timeZone: timeZone) {
            return EPGGuide(timeZone: timeZone, schedules: [schedule])
        }
        guard let parsed = EPGXMLTVParser.parse(data: data, key: key, timeZone: timeZone) else {
            throw CatVodError.parseFailed(
                flag: channel.name,
                reason: "节目单既不是 XMLTV 也不是 JSON：\(String(url.prefix(120)))"
            )
        }
        return parsed
    }

    /// 接口地址里的中文频道名：上游走 OkHttp，非 ASCII 会被它自动编码；这里补上同一手
    /// （`URL(string:)` 对**部分**非 ASCII 形态会造不出来），否则「拿频道名当参数」的接口在中文频道上直接失败。
    private func percentEncoded(_ url: String) -> String {
        guard url.hasPrefix("http"), URL(string: url) == nil else {
            return url
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: ":/?#[]@!$&'()*+,;=%")
        return url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url
    }

    /// 取一个节目单地址的**原始字节**（`.gz` 在这里解开）；便于单测与诊断。
    public func fetchData(_ entry: String, source: LiveSource) async throws -> Data {
        let url = try resolve(entry, source: source)
        let request = HTTPRequest(
            url: url,
            method: .get,
            headers: source.headers(),
            timeout: TimeInterval(max(source.timeout, 1))
        )
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: url.absoluteString,
                reason: "节目单「\(String(entry.prefix(120)))」返回非 2xx"
            )
        }
        guard GZipDecoder.looksLikeGzip(response.body) else {
            return response.body
        }
        guard let decoded = GZipDecoder.decode(response.body) else {
            throw CatVodError.parseFailed(
                flag: source.name,
                reason: "节目单 gzip 解压失败：\(String(entry.prefix(120)))"
            )
        }
        return decoded
    }

    /// 相对地址以直播源地址为基准解析（与 ``ConfigLocator/resolveURL(_:relativeTo:)`` 同一套约定）。
    private func resolve(_ entry: String, source: LiveSource) throws -> URL {
        let candidate = URL(string: source.url)
        let base = (candidate?.scheme?.isEmpty ?? true) ? nil : candidate
        // 注意：`URL(string:)` 对 `"not a url"` 也返回非 nil，所以只能靠 scheme 判断（与 `LiveRepository` 同一条）。
        guard let url = ConfigLocator.resolveURL(entry, relativeTo: base), url.scheme != nil, url.host != nil else {
            throw CatVodError.parseFailed(
                flag: source.name,
                reason: "节目单地址无法构造 URL：\(String(entry.prefix(120)))"
            )
        }
        return url
    }
}
