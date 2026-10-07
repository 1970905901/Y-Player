import CatVodCore
import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// 苹果CMS XML（`type=0` 站点）解析器。
///
/// 结构对照：`<rss><list page pagecount recordcount><video>…</video></list><class><ty id>…</ty></class></rss>`
/// 其中线路来自 `<dl><dd flag="线路名">第1集$id-1#第2集$id-2</dd></dl>`，
/// 多线路按出现顺序用 `$$$` 连接，与 `vod_play_from` / `vod_play_url` 的约定一致。
final class VodXMLParser: NSObject, XMLParserDelegate {
    private var result = SpiderResult()
    private var path: [String] = []
    private var text = ""

    private var currentVideo: [String: String] = [:]
    private var currentFlags: [String] = []
    private var currentEpisodes: [String] = []
    private var currentTypeID = ""
    private var insideDD = false

    /// 解析 XML 文本；失败返回 nil（调用方按协议错误处理，不把 HTML 当结果）。
    static func parse(data: Data) -> SpiderResult? {
        let parser = VodXMLParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        guard xml.parse() else {
            return nil
        }
        parser.finishVideo()
        return parser.result
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        path.append(name)
        text = ""

        switch name {
        case "list":
            if let page = attributeDict["page"], let value = Int(page) {
                result.page = max(value, 1)
            }
            if let pagecount = attributeDict["pagecount"], let value = Int(pagecount) {
                result.pagecount = max(value, 0)
            }
            if let recordcount = attributeDict["recordcount"], let value = Int(recordcount) {
                result.total = max(value, 0)
            }
        case "video":
            currentVideo = [:]
            currentFlags = []
            currentEpisodes = []
        case "dd":
            insideDD = true
            currentFlags.append(attributeDict["flag"] ?? "")
            currentEpisodes.append("") // 占位，随后由字符/CDATA 填充
        case "ty":
            currentTypeID = attributeDict["id"] ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
        appendToEpisode(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let chunk = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
        text += chunk
        appendToEpisode(chunk)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = path.popLast()

        switch name {
        case "video":
            finishVideo()
        case "dd":
            insideDD = false
        case "ty":
            if !currentTypeID.isEmpty, !value.isEmpty {
                result.categories.append(VodCategory(typeID: currentTypeID, typeName: value))
            }
            currentTypeID = ""
        case "id", "name", "type", "pic", "note", "year", "area", "actor", "director", "des", "last":
            if path.contains("video") {
                currentVideo[name] = value
            }
        default:
            break
        }
        text = ""
    }

    // MARK: - 组装

    private func appendToEpisode(_ chunk: String) {
        guard insideDD, !currentEpisodes.isEmpty else {
            return
        }
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        currentEpisodes[currentEpisodes.count - 1] += trimmed
    }

    private func finishVideo() {
        guard !currentVideo.isEmpty else {
            return
        }
        var item = VodItem()
        item.vodID = currentVideo["id"] ?? ""
        item.vodName = currentVideo["name"] ?? ""
        item.typeName = currentVideo["type"] ?? ""
        item.vodPic = currentVideo["pic"] ?? ""
        item.vodRemarks = currentVideo["note"] ?? ""
        item.vodYear = currentVideo["year"] ?? ""
        item.vodArea = currentVideo["area"] ?? ""
        item.vodActor = currentVideo["actor"] ?? ""
        item.vodDirector = currentVideo["director"] ?? ""
        item.vodContent = currentVideo["des"] ?? ""

        let episodes = currentEpisodes.filter { !$0.isEmpty }
        if !episodes.isEmpty {
            item.vodPlayFrom = currentFlags.isEmpty
                ? (0..<episodes.count).map { "线路 \($0 + 1)" }.joined(separator: PlaylistParser.lineSeparator)
                : currentFlags.joined(separator: PlaylistParser.lineSeparator)
            item.vodPlayURL = episodes.joined(separator: PlaylistParser.lineSeparator)
        }

        if !item.vodID.isEmpty {
            result.list.append(item)
        }
        currentVideo = [:]
        currentFlags = []
        currentEpisodes = []
    }
}
