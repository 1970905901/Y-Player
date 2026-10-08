import CatVodCore
import Foundation

// 「源缓存时间」的读取侧：缓存足够新鲜时**完全不联网**。
//
// 为什么单独一个文件：`SourceRepository` 主体的 `load(configURL:forceRefresh:)` 语义是
// 「联网优先、失败才回退缓存」（`docs/任务记录/M02P7-接口缓存管理.md` 记录的取舍），
// 而设置页的「源缓存时间」要求「有效期内直接用本地缓存」—— 这是两种不同的策略，
// 不能混进同一个函数，否则会把「离线回退」与「按有效期用缓存」两条路径搅在一起。

public extension SourceRepository {
    /// 缓存新鲜时返回本地配置；缓存不存在或已过期返回 nil（调用方按未命中处理，去联网）。
    ///
    /// - Parameter maxAge: 有效期秒数；`nil` 表示永不失效（只要求缓存存在）。
    ///
    /// 与 `load(configURL:forceRefresh:)` 的区别：**这里一次网络请求都不发**
    /// （JSON 源不请求配置地址，JS 源也不请求 `.md5` 摘要）。
    func loadCached(configURL raw: String, maxAge: TimeInterval?) async throws -> LoadedSource? {
        guard let source = ConfigLocator.locate(raw) else {
            return nil
        }
        switch source.kind {
        case .inline:
            // 内联配置本来就在内存里，没有「缓存文件」这回事。
            return nil
        case .json:
            guard let url = source.url else {
                return nil
            }
            let cacheURL = cacheDirectory.appendingPathComponent(source.cacheFileName)
            guard isFresh(cacheURL, maxAge: maxAge) else {
                return nil
            }
            let config = try decodeConfig(Data(contentsOf: cacheURL))
            return LoadedSource(
                kind: .json,
                config: config,
                originURL: url,
                cachedURL: cacheURL,
                usedCache: true,
                warnings: config.validationWarnings
            )
        case .javaScript:
            guard let url = source.url else {
                return nil
            }
            let directory = cacheDirectory.appendingPathComponent(ConfigLocator.scriptCacheDirectoryName(for: url))
            let cachedURL = directory.appendingPathComponent(ConfigLocator.scriptFileName)
            guard isFresh(cachedURL, maxAge: maxAge) else {
                return nil
            }
            // `.md5` 加在**完整文件名**之后：index.js → index.js.md5（与 JS 分支同一规则）。
            let stampURL = URL(fileURLWithPath: cachedURL.path + ConfigLocator.digestSuffix)
            return LoadedSource(
                kind: .javaScript,
                config: SourceConfig(),
                originURL: url,
                cachedURL: cachedURL,
                digest: readStamp(stampURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
                usedCache: true,
                warnings: ["按「源缓存时间」直接使用本地缓存配置，本次未联网校验"]
            )
        }
    }

    /// 文件是否在有效期内。
    ///
    /// 读不到修改时间（文件刚被别的进程动过、属性权限异常）时按**过期**处理：
    /// 宁可多联网一次，也不要拿一份时间来路不明的配置当「新鲜」。
    private func isFresh(_ url: URL, maxAge: TimeInterval?) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            return false
        }
        guard let maxAge else {
            return true
        }
        return Date().timeIntervalSince(modified) < maxAge
    }
}
