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
    /// （JSON 源不请求配置地址）。**JS 源不给结论**：`.md5` 增量校验不能省，
    /// 这里一律返回 nil，交给上面那条带校验的路（理由写在下面的 `.javaScript` 分支里）。
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
            // JS 源**故意不走这里的「纯本地」短路**。
            //
            // 上游给 js2p 接口配 `.md5` 就是为了增量更新：拉几十字节的摘要、变了才重下
            // 6 MB 的 bundle（参考实现每次都拉，超时 3 秒）。跳过这一步等于把「源缓存时间」
            // 变成「永不更新」—— 设成「永不」时用户会永远停在旧版本上（真踩过：
            // 8 月 1 日的 bundle 一直不换，见 docs/任务记录/M16P9）。
            //
            // 返回 nil 表示「这里给不了结论」：让上层走 `load(configURL:forceRefresh:)` 那条
            // 带 `.md5` 校验的路 —— 摘要一致仍然直接命中本地（**不重下 bundle**），
            // 拿不到摘要（离线 / 上游挂了）才退回已校验过的缓存。
            return nil
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
