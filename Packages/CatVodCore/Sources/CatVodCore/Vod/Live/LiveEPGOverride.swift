import Foundation

/// 直播 EPG 地址的**本地覆盖**（上游 `setting/LiveEpgSetting.java`）。
///
/// 上游把它存在本机偏好里（`live_epg_url`，另留 20 条历史），生效规则三条：
/// 1. `getEffectiveUrl(live)`：本地填了就用本地的，否则用源的 `epgApi`；
/// 2. `isGlobalXmlUrl(url)`：本地填的地址**不含 `{`** 就当作「整源一个 XML 文件」，
///    此时频道自己的 `epg` 会被清空（`channel.setEpg("")`），不再逐频道请求；
/// 3. `getXmlUrls(live)`：文件形态要拉的地址 = 本地那个整源 XML（如果有）+ 源自己的 `epgXml`（去重）。
///
/// 本项目照搬这三条，落地方式不同：上游就地改 `Live` / `Channel` 对象，这里是**纯函数** ——
/// ``applying(to:)`` 返回一份新的源（清单是解析结果的不可变值，改的是副本）。
public struct LiveEPGOverride: Sendable, Hashable {
    /// 本地填的地址（空 = 没覆盖）。首尾空白在构造时去掉（上游 `normalize`）。
    public var url: String

    public init(url: String = "") {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 没覆盖：源自己的 EPG 原样生效。
    public var isEmpty: Bool {
        url.isEmpty
    }

    /// 是不是「整源一个 XML 文件」（上游 `isGlobalXmlUrl`：非空且不含 `{`）。
    public var isGlobalXML: Bool {
        !url.isEmpty && !url.contains("{")
    }

    /// 覆盖生效后的源（纯函数：不动传入的那份）。
    ///
    /// 两件事：
    /// - 源级 `epg` 改成「覆盖地址 + 源自己的文件」：``LiveSource/epgAPI`` 取第一个含 `{` 的项，
    ///   所以模板会被覆盖地址顶掉；`.xml` / `.gz` 文件仍然留着（上游也保留 —— 它读的是源自己的字段）；
    /// - 每个频道的 `epg` **先清空再重算**：清空是上游的行为（`channel.setEpg("")`），
    ///   重算是为了模板形态 —— ``LiveChannel/inherit(from:)`` 只在频道自己为空时才展开模板。
    public func applying(to source: LiveSource) -> LiveSource {
        guard !isEmpty else {
            return source
        }
        var result = source
        result.epg = ([url] + source.epgXML).joined(separator: ",")
        // 值拷贝：给频道展开模板用（它们只看源级字段，不看 groups）。
        let template = result
        for groupIndex in result.groups.indices {
            for channelIndex in result.groups[groupIndex].channels.indices {
                result.groups[groupIndex].channels[channelIndex].epg = ""
                if isGlobalXML == false {
                    result.groups[groupIndex].channels[channelIndex].inherit(from: template)
                }
            }
        }
        return result
    }

    /// 文件形态要拉的地址（上游 `getXmlUrls`；去重保序）。
    ///
    /// 为什么要单独给一份而不是用 ``LiveSource/epgXML``：覆盖地址可能不带 `xml` / `gz` 字样
    /// （例如 `…/epg.php`），过不了那个过滤。传**原始**源最干净；传已经套过覆盖的那份也不会重复。
    public func fileURLs(for source: LiveSource) -> [String] {
        var items = isGlobalXML ? [url] : []
        items.append(contentsOf: source.epgXML)
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
