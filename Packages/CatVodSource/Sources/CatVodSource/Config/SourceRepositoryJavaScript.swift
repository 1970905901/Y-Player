import CatVodCore
import CatVodNet
import Foundation

// JS 源（js2p）分支：增量校验与 bundle 缓存。
//
// 规则**逐条对齐参考实现**（webhtv `NodeBundle`：类注释 + `ensureRemote` + `remoteSourceKey`）：
//
// | 项 | 参考做法 | 这里 |
// | --- | --- | --- |
// | 用户输入 | 「用户填的是 `.../index.js.md5`」—— bundle 在去掉 `.md5` 的地址上 | 同上（`ConfigLocator` 归一化，不报警） |
// | 元数据 | 只拉几十字节的 `.md5` 比对，超时 **3 秒**（「慢比错更难接受」） | 同上 |
// | 命中 | 摘要一致就用本地缓存，跳过下载 | 同上 |
// | 未校验内容 | **绝不下载未校验的 bundle**：拿不到校验值只允许用已校验过的缓存 | 同上 |
// | 落盘 | 运行目录固定 `index.js`（+ `index.js.md5`），目录私有可写 | 每接口一个 `bundle-<md5(url)>/` 目录，内含 `index.js` |

extension SourceRepository {
    func loadJavaScript(source: ConfigSource, forceRefresh: Bool) async throws -> LoadedSource {
        guard let url = source.url else {
            throw CatVodError.config(reason: "JS 源缺少地址")
        }
        let directory = cacheDirectory.appendingPathComponent(ConfigLocator.scriptCacheDirectoryName(for: url))
        let cachedURL = directory.appendingPathComponent(ConfigLocator.scriptFileName)
        // `.md5` 加在**完整文件名**之后：index.js → index.js.md5（不能用 deletingPathExtension）。
        let stampURL = URL(fileURLWithPath: cachedURL.path + ConfigLocator.digestSuffix)

        let remoteDigest = await fetchDigest(source.digestURL)
        let storedDigest = readStamp(stampURL)
        let hasCache = fileManager.fileExists(atPath: cachedURL.path)

        // 命中：远端摘要与本地记录一致 → 跳过 6 MB 下载。
        if !forceRefresh,
           hasCache,
           let remote = remoteDigest,
           !ConfigLocator.needsDownload(remoteDigest: remote, localDigest: storedDigest)
        {
            return cached(origin: url, cachedURL: cachedURL, digest: storedDigest, fallback: false)
        }

        // 拿不到校验值：只用已校验过的缓存，不下载未校验的内容（参考实现同款取舍）。
        guard let remote = remoteDigest else {
            guard hasCache else {
                throw CatVodError.config(
                    reason: "取不到远端 MD5 校验值（\(source.digestURL?.absoluteString ?? "<无地址>")），"
                        + "本地也还没有可用缓存，无法确认 bundle 完整性"
                )
            }
            return cached(origin: url, cachedURL: cachedURL, digest: storedDigest, fallback: true)
        }

        let response = try await transport.send(HTTPRequest(url: url, timeout: 60))
        guard response.isSuccess else {
            throw CatVodError.network(status: response.status, url: url.absoluteString, reason: "JS 源下载失败")
        }
        let digest = MD5.hexDigest(of: response.body)
        guard MD5.matches(digest, remote) else {
            throw CatVodError.config(reason: "JS 源摘要校验失败（远端 \(remote)，本地 \(digest)）")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try response.body.write(to: cachedURL, options: .atomic)
        try digest.write(to: stampURL, atomically: true, encoding: .utf8)

        return LoadedSource(
            kind: .javaScript,
            config: SourceConfig(),
            originURL: url,
            cachedURL: cachedURL,
            digest: digest,
            warnings: ["JS 源已就绪，站点清单由内嵌 Node 运行时提供（见 docs/js2p宿主契约.md）"]
        )
    }

    /// 已校验过的本地缓存（`fallback` 表示这次没拿到远端校验值，不是内容有问题）。
    private func cached(origin: URL, cachedURL: URL, digest: String?, fallback: Bool) -> LoadedSource {
        LoadedSource(
            kind: .javaScript,
            config: SourceConfig(),
            originURL: origin,
            cachedURL: cachedURL,
            digest: digest?.trimmingCharacters(in: .whitespacesAndNewlines),
            usedCache: true,
            usedOfflineFallback: fallback,
            warnings: fallback
                ? ["拿不到远端 MD5 校验值（网络或上游问题），已改用本地已校验过的缓存，未重新下载"]
                : []
        )
    }

    /// 取远端 32 字节摘要；任何异常都返回 nil。
    ///
    /// 三条与参考实现一致的口径：
    /// - **3 秒超时**：复用判定要抢在用户感知之前给结论；
    /// - 内容必须形如 32 位十六进制，否则按「没有校验值」处理；
    /// - 失败不抛错 —— 调用方据此决定是否退回缓存。
    func fetchDigest(_ url: URL?) async -> String? {
        guard let url else {
            return nil
        }
        guard let response = try? await transport.send(HTTPRequest(url: url, timeout: 3)),
              response.isSuccess,
              response.body.count <= 4096
        else {
            return nil
        }
        let text = String(data: response.body, encoding: .utf8) ?? ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return MD5.isDigest(value) ? value : nil
    }

    /// 读取本地已落盘的摘要（可能为空或坏值，由调用方按「无摘要」处理）。
    func readStamp(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
