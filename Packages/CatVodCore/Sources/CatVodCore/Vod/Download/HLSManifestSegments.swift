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

    /// 是不是主清单。
    public var isMaster: Bool
    /// 主清单的变体（按清单里的顺序）。
    public var variants: [Variant]
    /// 媒体清单的片段地址（**绝对地址**，顺序即拼接顺序）。
    public var segments: [String]
    /// 有没有加密片段（`#EXT-X-KEY` 的 `METHOD` 不是 `NONE`）。
    public var isEncrypted: Bool
    /// 有片段是按**字节范围**取的（`#EXT-X-BYTERANGE`）。
    ///
    /// 单列一个标记而不是默默忽略：那类清单里多个片段共用**同一个 URI**、靠范围区分，
    /// 不认它会下出「同一个文件下 N 遍」，还看不出哪里错。调用方据此如实拒绝（沿用本平台
    /// 对加密片段的那套：不支持的就说清楚，不猜）。
    public var isRangeBased: Bool
    /// 片段时长之和（秒）；解析不出来是 0 —— 只用于展示，不参与任何判定。
    public var totalDuration: Double

    public init(
        isMaster: Bool = false,
        variants: [Variant] = [],
        segments: [String] = [],
        isEncrypted: Bool = false,
        isRangeBased: Bool = false,
        totalDuration: Double = 0
    ) {
        self.isMaster = isMaster
        self.variants = variants
        self.segments = segments
        self.isEncrypted = isEncrypted
        self.isRangeBased = isRangeBased
        self.totalDuration = totalDuration
    }

    /// 能不能照着这份清单把内容拼出来（加密与字节范围都不支持，见各自说明）。
    public var isDownloadable: Bool {
        !isEncrypted && !isRangeBased
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
                    if isEncryptingKey(line) {
                        manifest.isEncrypted = true
                    }
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    manifest.isRangeBased = true
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
                    manifest.segments.append(absolute(mapURI, base: baseURL))
                }
                manifest.segments.append(resolved)
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

    /// `#EXT-X-KEY:` 是不是加密（`METHOD=NONE` 表示这段不加密）。
    static func isEncryptingKey(_ line: String) -> Bool {
        guard let method = attribute("METHOD", in: line) else {
            return false
        }
        return method.uppercased() != "NONE"
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
