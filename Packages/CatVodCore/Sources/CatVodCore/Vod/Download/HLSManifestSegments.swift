import Foundation

/// HLS 清单展开的结果：要下哪些地址（M10c）。
///
/// 三种形态各自的取法（按 RFC 8216 的最小子集，够用即可）：
/// - **主清单**（有 `#EXT-X-STREAM-INF`）→ `variants`，调用方按 ``bestVariant`` 选一条；
/// - **媒体清单**（有 `#EXTINF`）→ `segments`，按顺序就是拼接顺序；
/// - **既不是**（两者都空）→ 调用方把它当**普通文件**直下。
public struct HLSManifest: Sendable, Equatable {
    /// 一个变体（主清单里的 `#EXT-X-STREAM-INF` + 紧随其后的地址行）。
    public struct Variant: Sendable, Equatable {
        /// 绝对地址。
        public var url: String
        /// `BANDWIDTH`（缺失 = 0）。
        public var bandwidth: Int
    }

    /// 一段 `#EXT-X-KEY` 的加密信息（作用范围：它之后到下一段 `#EXT-X-KEY` 之前的所有片段；M10k）。
    public struct SegmentKey: Sendable, Equatable {
        /// `METHOD`（`AES-128` / `SAMPLE-AES`…；`NONE` 不会出现在这里）。
        public var method: String
        /// 密钥地址（已绝对化；可能为空 —— `SAMPLE-AES` 允许没有 URI）。
        public var uri: String
        /// 解密的 IV（**十六进制、已兜底**）：显式 `IV` 属性，或缺省时该片段的**媒体序号**（16 字节大端）。
        public var iv: String

        public init(method: String, uri: String = "", iv: String = "") {
            self.method = method
            self.uri = uri
            self.iv = iv
        }

        /// `iv`（十六进制，`0x` 前缀可有可无）→ 16 字节；长度 / 字符不对给 nil（宁可解不了明说，也不猜）。
        public func ivBytes() -> Data? {
            let text = iv.hasPrefix("0x") || iv.hasPrefix("0X") ? String(iv.dropFirst(2)) : iv
            guard text.count == 32 else {
                return nil
            }
            var bytes = Data(capacity: 16)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index ..< next], radix: 16) else {
                    return nil
                }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
    }

    /// 一个片段取哪一段字节（`#EXT-X-BYTERANGE`；M10l）。
    ///
    /// 同一条 URI 上的多个片段靠范围区分 —— `offset` 缺省时按 RFC 8216 接**上一段的结尾**，
    /// 这个兜底在解析时就做掉（下载器只管发 `Range` 头）。
    public struct SegmentRange: Sendable, Equatable {
        /// 起始字节。
        public var offset: Int
        /// 长度（字节）。
        public var length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    /// 前 `count` 片的指纹（含 init 片；M10n）。
    ///
    /// 逐个片段把 `URI + 字节范围` 喂进 FNV-1a（64 位，十六进制字符串）—— 续下要拿它
    /// 跟 ``DownloadTask/resumeFingerprint`` 对账：对得上才敢把新片段追加上去。
    ///
    /// 为什么按**前缀**算而不是整份清单：续下只关心「已经写进文件的那几片」没变 ——
    /// 清单在后面长出新片段（VOD 变长之类的写法）不该害得整份重下。
    public func segmentFingerprint(prefix count: Int) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func feed(_ text: String) {
            for byte in text.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            // 每片之间加一个分隔符：免得「(a,b)」与「(ab,)」喂出同一串字节。
            hash = (hash ^ 0x0A) &* 0x0000_0100_0000_01B3
        }
        for index in 0 ..< min(max(0, count), segments.count) {
            feed(segments[index])
            if segmentRanges.indices.contains(index), let range = segmentRanges[index] {
                feed("#\(range.offset)+\(range.length)")
            }
        }
        return String(hash, radix: 16)
    }

    /// 是不是主清单。
    public var isMaster: Bool
    /// 主清单的变体（按清单里的顺序）。
    public var variants: [Variant]
    /// 媒体清单的片段地址（**绝对地址**，顺序即拼接顺序）。
    public var segments: [String]
    /// 与 ``segments`` **一一对应**的加密信息（`nil` = 该片段不加密；M10k）。
    ///
    /// 为什么按片段存而不是只留一个「有没有加密」的标记：密钥可以在清单中途轮换
    /// （`#EXT-X-KEY` 作用到下一段 KEY 之前），而 IV 缺省时要用**该片段自己的媒体序号**推 ——
    /// 两件事都只有解析时知道，解密方（`DownloadRunner`）不该再猜。
    public var segmentKeys: [SegmentKey?]
    /// 与 ``segments`` **一一对应**的字节范围（`nil` = 整段取；M10l）。
    ///
    /// 与 ``segmentKeys`` 同一套并行数组的写法：三个数组都在解析的同两处一起填，
    /// 错位的风险由单测钉住（「谁在第几片」永远只按位置对应）。
    public var segmentRanges: [SegmentRange?]
    /// 有片段是**按字节范围**取的（`#EXT-X-BYTERANGE`）。
    ///
    /// 单列一个标记而不是默默忽略：那类清单里多个片段共用**同一个 URI**、靠范围区分，
    /// 不认它会下出「同一个文件下 N 遍」，还看不出哪里错。调用方据此如实拒绝（沿用本平台
    /// 对加密片段的那套：不支持的就说清楚，不猜）。
    public var isRangeBased: Bool
    /// 有字节范围**推不出来起点**（第一段就没写 `@offset`，不合 RFC 8216 的写法）——
    /// 这种清单不敢猜着下（猜错的后果是拼出一个错位的文件，还看不出来）。
    public var hasUnresolvableRange: Bool
    /// 清单里有 `#EXT-X-MAP`（fMP4 的初始化片，已作为第一个元素放进 `segments`）。
    ///
    /// 下载侧靠它决定落盘的**后缀**：有 init 片 = 拼接出来是 MP4 分段流（`.mp4`），
    /// 否则是 TS 流（`.ts`）—— 后缀错了，下一环（本地播放）就会拒开这个文件。
    public var hasInitializationSegment: Bool
    /// 片段时长之和（秒）；解析不出来是 0 —— 只用于展示，不参与任何判定。
    public var totalDuration: Double

    public init(
        isMaster: Bool = false,
        variants: [Variant] = [],
        segments: [String] = [],
        segmentKeys: [SegmentKey?] = [],
        segmentRanges: [SegmentRange?] = [],
        isRangeBased: Bool = false,
        hasUnresolvableRange: Bool = false,
        hasInitializationSegment: Bool = false,
        totalDuration: Double = 0
    ) {
        self.isMaster = isMaster
        self.variants = variants
        self.segments = segments
        self.segmentKeys = segmentKeys
        self.segmentRanges = segmentRanges
        self.isRangeBased = isRangeBased
        self.hasUnresolvableRange = hasUnresolvableRange
        self.hasInitializationSegment = hasInitializationSegment
        self.totalDuration = totalDuration
    }

    /// 有没有加密片段（任一 `#EXT-X-KEY` 的 `METHOD` 不是 `NONE`）。
    public var isEncrypted: Bool {
        segmentKeys.contains { $0 != nil }
    }

    /// 有没有**这套下载链路解不了**的加密：只认 `AES-128`（`SAMPLE-AES` 是另一套规范）。
    public var hasUnsupportedEncryption: Bool {
        segmentKeys.contains { key in
            guard let key else {
                return false
            }
            return key.method.uppercased() != "AES-128"
        }
    }

    /// 能不能照着这份清单把内容拼出来：加密只支持 `AES-128`；字节范围要推得出起点（见各自说明）。
    public var isDownloadable: Bool {
        !hasUnsupportedEncryption && !hasUnresolvableRange
    }

    /// 有没有可下的东西。
    public var hasContent: Bool {
        !segments.isEmpty || !variants.isEmpty
    }

    /// 主清单里选一条变体：**带宽最高的那条**。
    ///
    /// 下载场景下这个选择很直接 —— 用户要的是「存下来看」，没必要存低画质版本；
    /// 而带宽字段缺失的变体按 0 参与比较，若全都缺失，`max(by:)` 在并列时保留**靠前**的那条
    /// （比较器是严格递增），也就是清单里的第一条。
    public var bestVariant: Variant? {
        variants.max { $0.bandwidth < $1.bandwidth }
    }
}

/// 清单文本 → 「要下哪些地址」（M10c，纯逻辑）。
///
/// 为什么单独抽出来做：它的三个坑错了**都不会报错**，只会下出一堆没用的文件 ——
/// 相对地址不解析会下到拼接错的地址；`#EXT-X-MAP`（fMP4 的 init 片）漏了则整个文件播不了；
/// 加密片段不识别就存下一堆密文。所以规则写在这里，并由单测逐条钉住。
public enum HLSManifestParser {
    /// 展开一份清单。`baseURL` 是**清单自己的地址**（相对地址按它解析）。
    ///
    /// 不是清单（没有 `#EXTM3U`）时返回空结果，调用方据此按普通文件直下。
    public static func parse(text: String, baseURL: String) -> HLSManifest {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("#EXTM3U") }) else {
            return HLSManifest()
        }

        var manifest = HLSManifest()
        var pendingBandwidth = 0
        var pendingIsStreamInf = false
        var pendingIsSegment = false
        var mapURI = ""
        // 加密状态（M10k）：`currentKey` 作用到下一段 `#EXT-X-KEY`；序号用来给缺省 IV 兜底。
        var currentKey: HLSManifest.SegmentKey?
        var mediaSequence = 0
        var segmentSequence = 0
        // 字节范围（M10l）：`#EXT-X-BYTERANGE` 作用到下一个片段；缺 offset 时接上一段的结尾。
        var pendingRange: HLSManifest.SegmentRange?
        var lastRangeEnd: Int?

        for line in lines {
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    manifest.isMaster = true
                    pendingIsStreamInf = true
                    pendingBandwidth = bandwidth(in: line)
                } else if line.hasPrefix("#EXTINF:") {
                    pendingIsSegment = true
                    manifest.totalDuration += duration(in: line)
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    currentKey = Self.key(from: line, baseURL: baseURL)
                } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    let payload = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                    mediaSequence = Int(payload.trimmingCharacters(in: .whitespaces)) ?? 0
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    manifest.isRangeBased = true
                    pendingRange = nil
                    let payload = line.dropFirst("#EXT-X-BYTERANGE:".count)
                        .trimmingCharacters(in: .whitespaces)
                    let parts = payload.split(separator: "@", maxSplits: 1)
                    let length = Int(parts.first ?? "") ?? 0
                    let offset = parts.count == 2 ? Int(parts[1]) : lastRangeEnd
                    if length > 0, let offset {
                        pendingRange = HLSManifest.SegmentRange(offset: offset, length: length)
                    } else {
                        // 推不出起点：记下来，整份清单如实拒绝（M10l）。
                        manifest.hasUnresolvableRange = true
                    }
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    mapURI = attribute("URI", in: line) ?? ""
                }
                continue
            }

            // 非标签行：要么是变体地址，要么是片段地址，要么什么都不是（比如夹杂的注释文字）。
            let resolved = absolute(line, base: baseURL)
            if pendingIsStreamInf {
                manifest.variants.append(HLSManifest.Variant(url: resolved, bandwidth: pendingBandwidth))
                pendingIsStreamInf = false
                pendingBandwidth = 0
            } else if pendingIsSegment {
                // fMP4 的 init 片必须**排在最前**：没有它，后面的片段是解不出来的裸流。
                if manifest.segments.isEmpty, !mapURI.isEmpty {
                    manifest.hasInitializationSegment = true
                    manifest.segments.append(absolute(mapURI, base: baseURL))
                    // init 片不吃媒体序号、也不带 KEY（它是开头，不是加密序列的一段）。
                    manifest.segmentKeys.append(nil)
                    manifest.segmentRanges.append(nil)
                }
                manifest.segments.append(resolved)
                manifest.segmentKeys.append(
                    Self.resolvedKey(currentKey, sequence: mediaSequence + segmentSequence)
                )
                segmentSequence += 1
                manifest.segmentRanges.append(pendingRange)
                if let pendingRange {
                    lastRangeEnd = pendingRange.offset + pendingRange.length
                }
                pendingRange = nil
                pendingIsSegment = false
            }
        }
        return manifest
    }

    // MARK: - 内部

    /// 相对地址 → 绝对地址。
    ///
    /// 两种写法都要认：`seg-1.ts`（相对清单所在目录）与 `/v/seg-1.ts`（相对主机根）。
    /// 用 `URL(string:relativeTo:)` 而不是自己拼字符串 —— `../` 这类写法自己拼必错。
    static func absolute(_ raw: String, base: String) -> String {
        if raw.contains("://") {
            return raw
        }
        guard let baseURL = URL(string: base) else {
            return raw
        }
        return URL(string: raw, relativeTo: baseURL)?.absoluteString ?? raw
    }

    /// `BANDWIDTH=1234`（解析不出来 = 0）。
    static func bandwidth(in line: String) -> Int {
        guard let text = attribute("BANDWIDTH", in: line) else {
            return 0
        }
        return Int(text) ?? 0
    }

    /// `#EXTINF:9.009,标题` 里的秒数。
    static func duration(in line: String) -> Double {
        guard let colon = line.firstIndex(of: ":") else {
            return 0
        }
        let payload = line[line.index(after: colon)...]
        let seconds = payload.split(separator: ",").first.map(String.init) ?? ""
        return Double(seconds.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// `#EXT-X-KEY:` → 加密信息；`METHOD=NONE`（或没有 METHOD）给 nil = 从这里起不加密。
    ///
    /// IV 的兜底（用片段的媒体序号）不在这里做 —— 那是**片段**的属性，见 ``resolvedKey(_:sequence:)``。
    static func key(from line: String, baseURL: String) -> HLSManifest.SegmentKey? {
        guard let method = attribute("METHOD", in: line), method.uppercased() != "NONE" else {
            return nil
        }
        let rawURI = attribute("URI", in: line) ?? ""
        return HLSManifest.SegmentKey(
            method: method.uppercased(),
            uri: rawURI.isEmpty ? "" : absolute(rawURI, base: baseURL),
            iv: attribute("IV", in: line) ?? ""
        )
    }

    /// 给一段加密信息补上缺省 IV：RFC 8216 规定「没有 `IV` 属性时用该片段的**媒体序号**（16 字节大端）」。
    static func resolvedKey(_ key: HLSManifest.SegmentKey?, sequence: Int) -> HLSManifest.SegmentKey? {
        guard var key else {
            return nil
        }
        if key.iv.isEmpty {
            key.iv = hexIV(sequence: sequence)
        }
        return key
    }

    /// 媒体序号 → `0x…` 的 16 字节大端十六进制。
    static func hexIV(sequence: Int) -> String {
        var text = String(UInt64(max(0, sequence)), radix: 16)
        text = String(repeating: "0", count: max(0, 32 - text.count)) + text
        return "0x" + text
    }

    /// 取 `KEY=VALUE` 形式的值；`VALUE` 可能带引号（`URI="init.mp4"`）。
    static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=") else {
            return nil
        }
        var value = String(line[range.upperBound...])
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") {
                value = String(value[..<end])
            }
        } else if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
