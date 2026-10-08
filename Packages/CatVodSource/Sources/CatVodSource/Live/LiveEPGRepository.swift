import CatVodCore
import CatVodNet
import Foundation

/// EPG 加载：取节目单文件 → ``EPGXMLTVParser`` → 合并成一个 ``EPGGuide``。
///
/// 对照上游 `EpgParser.start` 的**文件**分支（`epg` 里不是 x-tvg 接口的那些地址）：
/// - 一个源可以配多个地址（例如「央视.xml,卫视.xml.gz」），逐个拉取后用 ``EPGGuide/merging(_:)`` 合并；
/// - 请求带源级 ``LiveSource/headers()`` 与 ``LiveSource/timeout``（与 ``LiveRepository`` 同一套）；
/// - `.gz` 按**魔数**识别并解压（见 ``GZipDecoder``），不信地址扩展名；
/// - 非 2xx、地址非法、不是 XMLTV、解压失败一律抛 ``CatVodError``，**全失败才算失败**
///   （部分地址坏不影响已经拿到的节目单）。
///
/// 未做（明确报错，不静默返回空节目单）：`epg` 里的 x-tvg 接口（含 `{…}` 时间窗模板）属 M07c，
/// 要用 ``EPGProgram/clockQuery`` 拼 `clock=` 窗口再按 JSON 解析。
public struct LiveEPGRepository: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 拉取并解析一个直播源的节目单。
    public func load(_ source: LiveSource) async throws -> EPGGuide {
        let entries = source.epgXML
        guard !entries.isEmpty else {
            throw CatVodError.unsupported(
                feature: "直播源「\(source.name)」的节目单",
                reason: source.epg.isEmpty
                    ? "epg 字段为空"
                    : "只配了 x-tvg 接口（含 `{…}` 时间窗），本轮只支持 XML/GZ 文件"
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
