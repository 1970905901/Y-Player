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

        switch source.kind {
        case .inline:
            let config = try decodeConfig(Data(raw.utf8))
            return LoadedSource(kind: .json, config: config, warnings: config.validationWarnings)
        case .json:
            return try await loadJSON(source: source, forceRefresh: forceRefresh)
        case .javaScript:
            return try await loadJavaScript(source: source, forceRefresh: forceRefresh)
        }
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
            throw CatVodError.config(reason: "配置不是合法 JSON：\(error)")
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
