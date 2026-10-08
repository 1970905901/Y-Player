import Foundation

/// 一条弹幕（真正的弹幕行），对齐上游 `bean/DanmakuData.java`。
///
/// 参数串是经典 B 站格式：`p="出现时间,类型,字号,颜色,…"` —— 逗号分隔、**至少 4 段**
/// （后面几段是弹幕池 / 用户 id / 时间戳，本项目不关心）。
public struct DanmakuLine: Sendable, Hashable {
    /// 出现时间（秒）。
    public var time: Double
    /// 位置类型：1 滚动、4 底部、5 顶部（其它值按滚动处理）。
    public var type: Int
    /// 字号（弹幕文件里的原始值；屏幕密度的换算留给渲染层）。
    public var size: Double
    /// 颜色（ARGB，已强制补成不透明）。
    public var color: UInt32
    /// 文本（HTML 实体已反转义）。
    public var text: String

    public var isScroll: Bool {
        type != 4 && type != 5
    }

    public var isTop: Bool {
        type == 5
    }

    public var isBottom: Bool {
        type == 4
    }

    /// 描边色：颜色**数值**不大于纯黑就用白、否则用黑（上游 `shadow` 的原判法）。
    ///
    /// 这条判法很粗：`#111111` 这样的深灰会拿到黑描边（对比度差）。照抄是有意的 ——
    /// 上游的观感基准就是它，自己「改良」会让同一份弹幕在两端看起来不一样。
    public var shadowColor: UInt32 {
        color <= 0xFF00_0000 ? 0xFFFF_FFFF : 0xFF00_0000
    }

    /// 从参数串与文本构造；字段不足 / 时间解析不出来时返回 nil（坏行跳过，不让整份文件作废）。
    public init?(params: String, text: String) {
        let fields = params.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, let time = Double(fields[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        self.time = time
        type = Int(fields[1].trimmingCharacters(in: .whitespaces)) ?? 1
        size = Double(fields[2].trimmingCharacters(in: .whitespaces)) ?? 25
        color = Self.opaqueColor(fields[3].trimmingCharacters(in: .whitespaces))
        self.text = Self.unescaped(text)
    }

    /// 颜色：十进制 → 强制补成不透明 ARGB（上游 `0xFF000000 | value` 的等价写法）。
    static func opaqueColor(_ value: String) -> UInt32 {
        let raw = UInt32(value.trimmingCharacters(in: .whitespaces)) ?? 0xFFFFFF
        return 0xFF00_0000 | (raw & 0x00FF_FFFF)
    }

    /// 反转义四种 HTML 实体（上游 `getText` 只做这四个）。
    static func unescaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
    }
}

/// 弹幕文件（经典 B 站 XML：`<d p="…">文本</d>`）的解析。
public enum DanmakuDocument {
    /// 抽出所有弹幕行，按时间排序；坏行跳过。
    ///
    /// 为什么手写扫描、不用 `XMLParser`：弹幕文件动辄几 MB、几万条，SAX 在这里没有优势，
    /// 而**容错要求更高**（末尾截断、`p` 字段数不对、实体写法随意）——
    /// 手写扫描能把「坏的跳过、好的照收」写清楚，也好测。
    public static func parse(_ text: String) -> [DanmakuLine] {
        var lines: [DanmakuLine] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard let start = find("<d ", in: characters, from: index) else {
                break
            }
            guard let paramStart = find("p=\"", in: characters, from: start + 3),
                  let paramEnd = find("\"", in: characters, from: paramStart + 3)
            else {
                index = start + 3
                continue
            }
            let params = String(characters[(paramStart + 3) ..< paramEnd])
            guard let tagEnd = find(">", in: characters, from: paramEnd + 1) else {
                break
            }
            // 自闭合 `<d p="…"/>`：没有文本，跳过（少见但要认）
            if tagEnd > 0, characters[tagEnd - 1] == "/" {
                index = tagEnd + 1
                continue
            }
            guard let close = find("</d>", in: characters, from: tagEnd + 1) else {
                break
            }
            let body = String(characters[(tagEnd + 1) ..< close])
            if let line = DanmakuLine(params: params, text: body) {
                lines.append(line)
            }
            index = close + 4
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// 在字符数组里找一段字面量（返回起始下标）。
    private static func find(_ needle: String, in characters: [Character], from index: Int) -> Int? {
        let pattern = Array(needle)
        guard !pattern.isEmpty, index < characters.count else {
            return nil
        }
        var cursor = index
        while cursor + pattern.count <= characters.count {
            if Array(characters[cursor ..< (cursor + pattern.count)]) == pattern {
                return cursor
            }
            cursor += 1
        }
        return nil
    }
}
