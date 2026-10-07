import CatVodCore
import CatVodNet
import Foundation

/// 源配置仓库：负责「定位 → 增量校验 → 下载/缓存 → 解析」。
///
/// 关键行为：
/// - **JS 源**：先取 `index.js.md5`（32 字节）比对本地摘要，一致就直接用缓存的 6 MB bundle；
/// - **JSON 配置**：优先联网，网络失败退回上次缓存并标记 `usedOfflineFallback`；
/// - **内联 JSON**：用户粘贴的配置直接解析，不落盘。
///
/// 说明：存储属性为模块内可见，供同模块的扩展文件（JSON / JS 源分支）复用。
public actor SourceRepository {
    let transport: HTTPTransport
    let cacheDirectory: URL
    let fileManager: FileManager

    public init(transport: HTTPTransport, cacheDirectory: URL, fileManager: FileManager = .default) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
    }

    /// 加载配置。
    ///
    /// - Parameter forceRefresh: 忽略缓存强制重新下载（用户手动「刷新接口」时使用）。
    public func load(configURL raw: String, forceRefresh: Bool = false) async throws -> LoadedSource {
        guard let source = ConfigLocator.locate(raw) else {
            throw CatVodError.config(reason: "配置地址无法解析：\(raw)")
        }
        try ensureCacheDirectory()

        let loaded: LoadedSource
        switch source.kind {
        case .inline:
            let config = try decodeConfig(Data(raw.utf8))
            loaded = LoadedSource(kind: .json, config: config, warnings: config.validationWarnings)
        case .json:
            loaded = try await loadJSON(source: source, forceRefresh: forceRefresh)
        case .javaScript:
            loaded = try await loadJavaScript(source: source, forceRefresh: forceRefresh)
        }
        return loaded
    }

    // MARK: - 辅助（同模块扩展也使用）

    func decodeConfig(_ data: Data) throws -> SourceConfig {
        guard !data.isEmpty else {
            throw CatVodError.config(reason: "配置内容为空")
        }
        let config: SourceConfig
        do {
            config = try JSONDecoder().decode(SourceConfig.self, from: data)
        } catch {
            // 不把 `DecodingError` 原文甩给用户：真机上它长这样 ——
            // `dataCorrupted(… NSJSONSerializationErrorIndex=2)`，看的人不知道该改什么。
            throw CatVodError.config(reason: Self.describeNonJSON(data))
        }
        // 上游把 `msg` 视为错误响应，必须直接失败。
        if config.isErrorResponse {
            throw CatVodError.config(reason: config.msg)
        }
        if config.sites.isEmpty {
            throw CatVodError.configHasNoUsableSite
        }
        return config
    }

    func ensureCacheDirectory() throws {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - JSON 配置

extension SourceRepository {
    func loadJSON(source: ConfigSource, forceRefresh: Bool) async throws -> LoadedSource {
        guard let url = source.url else {
            throw CatVodError.config(reason: "JSON 配置缺少地址")
        }
        let cacheURL = cacheDirectory.appendingPathComponent(source.cacheFileName)

        do {
            let response = try await transport.send(HTTPRequest(url: url, timeout: 30))
            guard response.isSuccess else {
                throw CatVodError.network(status: response.status, url: url.absoluteString, reason: "配置下载失败")
            }
            let config = try decodeConfig(response.body)
            try? response.body.write(to: cacheURL, options: .atomic)
            return LoadedSource(
                kind: .json,
                config: config,
                originURL: url,
                cachedURL: cacheURL,
                warnings: config.validationWarnings
            )
        } catch {
            // 离线回退：有缓存就用缓存，并把真实原因作为告警透出。
            guard !forceRefresh, fileManager.fileExists(atPath: cacheURL.path) else {
                throw error
            }
            let data = try Data(contentsOf: cacheURL)
            let config = try decodeConfig(data)
            let reason = (error as? CatVodError)?.errorDescription ?? error.localizedDescription
            return LoadedSource(
                kind: .json,
                config: config,
                originURL: url,
                cachedURL: cacheURL,
                usedCache: true,
                usedOfflineFallback: true,
                warnings: ["网络不可用，已使用本地缓存配置：\(reason)"] + config.validationWarnings
            )
        }
    }
}

// MARK: - 面向用户的失败说明

extension SourceRepository {
    /// 把「不是 JSON」翻译成**可操作**的说明。
    ///
    /// 实测最容易踩到的两种输入都给确切指引：
    /// - 填了同目录的 `.md5` 校验文件（32 位十六进制摘要，以数字开头时 JSON 恰好会在第 2 列报错）；
    /// - 填了 JS bundle 的地址但没以 `.js` 结尾，于是被当成 JSON 配置。
    static func describeNonJSON(_ data: Data) -> String {
        let head = String(decoding: data.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let digest = digestLikeHead(head) {
            return "远端返回的是 MD5 校验文本（\(digest)），不是配置。"
                + "若这是猫源接口，请填写同目录下的 index.js 或 index.js.md5"
        }
        if isScriptLike(head) {
            return "远端返回的像是 JS 脚本（开头 \(head.prefix(24))…，共 \(data.count) 字节），不是 JSON 配置。"
                + "若这是 JS 源，请确认地址以 .js 结尾"
        }
        return "远端返回的不是 JSON 配置（\(data.count) 字节，开头：\(head.prefix(48))）"
    }

    /// 开头是 32 位十六进制摘要时返回它，否则 nil（容忍尾部换行与后面的文件名）。
    private static func digestLikeHead(_ head: String) -> String? {
        let token = head.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? head
        guard token.count >= 32 else {
            return nil
        }
        let candidate = String(token.prefix(32))
        return candidate.allSatisfy(\.isHexDigit) ? candidate : nil
    }

    /// 开头像 JS 脚本（bundle 的常见形态）。
    private static func isScriptLike(_ head: String) -> Bool {
        ["!function", "(function", "function ", "var ", "const ", "let ", "import ", "/*"]
            .contains { head.hasPrefix($0) }
    }
}
