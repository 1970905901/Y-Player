import Foundation

/// 配置入口类型。
///
/// 实测结论（2026-10-07）：
/// - `https://…/ceshi/index.js.md5` 是 32 字节的 MD5 校验文件；
/// - 真正的配置是 `https://…/ceshi/index.js`（`text/javascript`，6,291,879 字节的 esbuild bundle）。
/// 因此配置入口同时支持 JSON 与 JS 两种形态，并对 `.js` 自动关联同目录的 `.js.md5`。
public struct ConfigSource: Sendable, Hashable {
    public enum Kind: String, Sendable {
        /// 普通猫源 JSON 配置。
        case json
        /// JS 源 bundle（js2p 宿主型），需在 JS 运行时中执行。
        case javaScript
        /// 内联 JSON 文本（用户手动粘贴）。
        case inline
    }

    public var url: URL?
    /// 与 `url` 同目录的 `.md5` 校验地址；JSON 配置通常没有。
    public var digestURL: URL?
    public var kind: Kind
    /// 本地缓存文件名（按 URL 摘要生成，避免同名冲突）。
    public var cacheFileName: String

    public init(url: URL?, digestURL: URL?, kind: Kind, cacheFileName: String) {
        self.url = url
        self.digestURL = digestURL
        self.kind = kind
        self.cacheFileName = cacheFileName
    }
}

public enum ConfigLocator {
    public static let jsonCacheExtension = "json"
    public static let scriptCacheExtension = "js"
    public static let digestSuffix = ".md5"

    /// 解析用户输入的配置地址。
    ///
    /// - 以 `{` 开头视为内联 JSON；
    /// - 以 `.js` 结尾视为 JS 源并关联 `.js.md5`；
    /// - 其余按 JSON 配置处理。
    public static func locate(_ raw: String, relativeTo base: URL? = nil) -> ConfigSource? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        if text.hasPrefix("{") {
            return ConfigSource(
                url: nil,
                digestURL: nil,
                kind: .inline,
                cacheFileName: "inline-\(MD5.hexDigest(of: text)).json"
            )
        }

        guard let url = resolveURL(text, relativeTo: base) else {
            return nil
        }

        if isJavaScriptConfig(url) {
            return ConfigSource(
                url: url,
                digestURL: digestURL(for: url),
                kind: .javaScript,
                cacheFileName: cacheFileName(for: url, extension: scriptCacheExtension)
            )
        }

        return ConfigSource(
            url: url,
            digestURL: nil,
            kind: .json,
            cacheFileName: cacheFileName(for: url, extension: jsonCacheExtension)
        )
    }

    /// 是否为 JS 源配置。
    public static func isJavaScriptConfig(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "js"
    }

    /// JS 源对应的校验地址：`index.js` → `index.js.md5`。
    ///
    /// 注意：`.md5` 是加在完整文件名之后，不能用 `deletingPathExtension` 再拼，
    /// 否则会得到 `index.md5`。
    public static func digestURL(for url: URL) -> URL? {
        URL(string: url.absoluteString + digestSuffix)
    }

    /// 相对路径以配置文件 URL 为基准解析（webhtv 总配置接入约定）。
    public static func resolveURL(_ text: String, relativeTo base: URL?) -> URL? {
        if let absolute = URL(string: text), absolute.scheme != nil {
            return absolute
        }
        guard let base else {
            return nil
        }
        return URL(string: text, relativeTo: base)?.absoluteURL
    }

    /// 缓存文件名：`config-<md5(url)>.<ext>`。
    public static func cacheFileName(for url: URL, extension ext: String) -> String {
        "config-\(MD5.hexDigest(of: url.absoluteString)).\(ext)"
    }

    /// 用远端 `.md5` 文本校验本地 bundle 是否需要更新。
    ///
    /// - 校验文本为空 → 视为「无校验信息」，需要重新下载；
    /// - 与本地摘要一致 → 命中缓存，跳过下载（6 MB 的 bundle 不该反复拉）。
    public static func needsDownload(remoteDigest: String, localDigest: String?) -> Bool {
        let remote = remoteDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            return true
        }
        guard let local = localDigest?.trimmingCharacters(in: .whitespacesAndNewlines), !local.isEmpty else {
            return true
        }
        return !MD5.matches(remote, local)
    }
}
