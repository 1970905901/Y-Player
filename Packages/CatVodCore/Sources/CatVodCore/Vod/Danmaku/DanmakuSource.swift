import Foundation

/// 一条弹幕**来源**（一个可下载的弹幕文件地址），对应上游 `bean/Danmaku.java`。
///
/// 「来源」这个词容易混：搜索接口返回的是一批**候选**（每条的 `url` 指向真正的弹幕文件），
/// 播放器挑第一条非空的去下载 —— 真正的弹幕行在 ``DanmakuLine`` 里。
///
/// 解析刻意**非常宽容**（逐条对齐上游 `arrayFrom`）：同一个接口名下的返回形状五花八门，
/// 少认一种就少一个可用的源：
/// - JSON 数组 → 逐项；
/// - 裸字符串 → 当一条来源（`url` 就是它自己）；
/// - 对象 → 先看 `data` / `list` / `result` / `results` / `items` / `danmakus` / `danmaku` 里有没有数组；
/// - 其它对象 → 当一条来源；
/// - 字符串里以 `[` / `{` 开头 → 再当 JSON 解一次。
///
/// 全部为空 / 认不出来 → 空数组（上游 `filter` 会丢掉没有 `url` 的项）。
/// ⚠️ 这里曾经有**两份**同名建模：本文件一份（解析弹幕搜索接口的候选来源），
/// `Vod/Models/MediaExtras.swift` 另一份（只被 `SpiderResult.danmaku` 的声明引用，
/// 没有任何生产消费方，字段还少了 `source`）。同一个模块里出现两个顶层同名类型是**编译错误**
/// （`'DanmakuSource' is ambiguous for type lookup in this context`，CI 抓到、本地语法检查看不到）。
/// 已合并为这一个：`Codable` / `Identifiable` 从那一份搬来，字段以本文件为准。
///
/// 那一份还有个 `extras: [String: String]`，但它的 `init(from:)` 里是**硬写空数组** ——
/// 从来没有被真正解析出来过，所以合并时没有搬（不搬一个僵尸字段）。
public struct DanmakuSource: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var url: String
    /// 接口自己声明的来源名（`source` / `from` / `site` / `provider` / `platform` 任一）。
    public var source: String

    public var id: String { "\(name)|\(url)" }

    public init(name: String = "", url: String = "", source: String = "") {
        self.name = name
        self.url = url
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        url = container.lenientString(.url)
        source = container.lenientString(.source)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case source
    }

    /// 展示名：没有 `name` 就回落 `url`（上游 `getName`）。
    public var displayName: String {
        name.isEmpty ? url : name
    }

    /// 解析搜索接口的响应体。
    public static func array(from body: String) -> [DanmakuSource] {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return []
        }
        if let data = text.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data)
        {
            return filter(parse(value))
        }
        // 上游的 `catch` 分支：JSON 解不出来就把整段当一条来源（`Danmaku.from(str)`）
        return filter([DanmakuSource(name: text, url: text)])
    }

    // MARK: - 内部

    /// 递归解析任意 JSON 形状（上游 `arrayFrom(JsonElement, Type)`）。
    private static func parse(_ value: Any) -> [DanmakuSource] {
        if let array = value as? [Any] {
            return array.flatMap { parse($0) }
        }
        if let text = value as? String {
            return parseString(text)
        }
        if let object = value as? [String: Any] {
            for key in nestedKeys {
                if let nested = object[key] {
                    let items = parse(nested)
                    if !items.isEmpty {
                        return items
                    }
                }
            }
            return [source(from: object)]
        }
        return []
    }

    /// 字符串：以 `[` / `{` 开头就当 JSON 再解一次，否则当一条来源。
    private static func parseString(_ text: String) -> [DanmakuSource] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data)
        {
            return parse(value)
        }
        return [DanmakuSource(name: trimmed, url: trimmed)]
    }

    /// 只取有 `url` 的项（上游 `filter` 的 `isEmpty` 判定）。
    private static func filter(_ items: [DanmakuSource]) -> [DanmakuSource] {
        items.filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func source(from object: [String: Any]) -> DanmakuSource {
        DanmakuSource(
            name: string(object, keys: ["name"]),
            url: string(object, keys: ["url"]),
            source: string(object, keys: ["source", "from", "site", "provider", "platform"])
        )
    }

    /// 取第一个非空字符串（上游的 `@SerializedName(alternate:)` 语义；数字也当字符串收）。
    private static func string(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.stringValue
            }
        }
        return ""
    }

    private static let nestedKeys = ["data", "list", "result", "results", "items", "danmakus", "danmaku"]
}
