import Foundation

/// 播放地址的前缀指令。
///
/// 对照 webhtv `docs/integration/parser.md` 的「playUrl 前缀」表：
/// - `json:{url}`：临时使用 `type=1` 解析器，地址为 `{url}`；
/// - `parse:{name}`：使用配置里 `name` 等于 `{name}` 的解析器；
/// - 无前缀且非空：作为 `type=0` Web 解析地址。
public enum PlaybackInstruction: Sendable, Hashable {
    /// JSON 解析：`json:{url}`。
    case json(url: String)
    /// 指定名称的解析器：`parse:{name}`。
    case parser(name: String)
    /// Web 解析：直接给出解析页面地址。
    case web(url: String)
    /// 无需解析（空指令）。
    case none
}

public enum PlayUrlPrefix {
    public static let jsonPrefix = "json:"
    public static let parsePrefix = "parse:"

    /// 解析单条指令文本（不含站点级回退）。
    public static func route(_ raw: String) -> PlaybackInstruction {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .none
        }
        if text.hasPrefix(jsonPrefix) {
            let url = String(text.dropFirst(jsonPrefix.count))
            return url.isEmpty ? .none : .json(url: url)
        }
        if text.hasPrefix(parsePrefix) {
            let name = String(text.dropFirst(parsePrefix.count))
            return name.isEmpty ? .none : .parser(name: name)
        }
        return .web(url: text)
    }

    /// 只看**前缀**的指令：`json:` → `.json`，`parse:` → `.parser`，其余（含裸地址、空串）返回 `nil`。
    ///
    /// 为什么要它：上游 `ParseJob.setParse`（webhtv）里裸地址**不覆盖**已经选中的解析器 ——
    /// 裸地址只在「结果需要解析但没有解析器可选」时作为 `type=0` 的解析页兜底。
    /// ``route(_:)`` 会把裸地址当成 `.web`，用在那两行判断里就会得出与上游相反的结论。
    public static func prefixedInstruction(_ raw: String) -> PlaybackInstruction? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        if text.hasPrefix(jsonPrefix) {
            let url = String(text.dropFirst(jsonPrefix.count))
            return url.isEmpty ? nil : .json(url: url)
        }
        if text.hasPrefix(parsePrefix) {
            let name = String(text.dropFirst(parsePrefix.count))
            return name.isEmpty ? nil : .parser(name: name)
        }
        return nil
    }

    /// 结果级 `playUrl` 优先，为空时回退站点级 `playUrl`。
    ///
    /// 依据 webhtv `docs/integration/player.md`：`playUrl` 来自播放结果，
    /// 站点级 `playUrl` 只作为「站点级播放前缀或解析辅助」。
    public static func resolve(sitePlayUrl: String, resultPlayUrl: String) -> PlaybackInstruction {
        let resolved = route(resultPlayUrl)
        if case .none = resolved {
            return route(sitePlayUrl)
        }
        return resolved
    }

    /// 该指令是否指向一个已配置的解析器。
    public static func parserName(in instruction: PlaybackInstruction) -> String? {
        if case let .parser(name) = instruction {
            return name
        }
        return nil
    }
}
