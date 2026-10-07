import CatVodCore
import CatVodNet
import Foundation

// JS 源（js2p）分支：增量校验与 6 MB bundle 缓存。
//
// 更新流程对照 `docs/js2p宿主契约.md`：先取 `index.js.md5`（32 字节），
// 与本地缓存摘要一致则跳过下载；不一致才重新拉取并校验。

extension SourceRepository {
    func loadJavaScript(source: ConfigSource, forceRefresh: Bool) async throws -> LoadedSource {
        guard let url = source.url else {
            throw CatVodError.config(reason: "JS 源缺少地址")
        }
        let cacheURL = cacheDirectory.appendingPathComponent(source.cacheFileName)
        let digestURL = cacheDirectory.appendingPathComponent(source.cacheFileName + ".md5")

        let remoteDigest = try await fetchDigest(source.digestURL)
        let storedDigest = try? String(contentsOf: digestURL, encoding: .utf8)

        if !forceRefresh,
           fileManager.fileExists(atPath: cacheURL.path),
           !ConfigLocator.needsDownload(remoteDigest: remoteDigest ?? "", localDigest: storedDigest)
        {
            // 摘要一致：跳过 6 MB 下载。
            return LoadedSource(
                kind: .javaScript,
                config: SourceConfig(),
                originURL: url,
                cachedURL: cacheURL,
                digest: storedDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
                usedCache: true
            )
        }

        let response = try await transport.send(HTTPRequest(url: url, timeout: 60))
        guard response.isSuccess else {
            throw CatVodError.network(status: response.status, url: url.absoluteString, reason: "JS 源下载失败")
        }
        let digest = MD5.hexDigest(of: response.body)
        if let remote = remoteDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remote.isEmpty,
           !MD5.matches(digest, remote)
        {
            throw CatVodError.config(reason: "JS 源摘要校验失败（远端 \(remote)，本地 \(digest)）")
        }
        try response.body.write(to: cacheURL, options: .atomic)
        try digest.write(to: digestURL, atomically: true, encoding: .utf8)

        return LoadedSource(
            kind: .javaScript,
            config: SourceConfig(),
            originURL: url,
            cachedURL: cacheURL,
            digest: digest,
            warnings: ["JS 源需由内嵌 Node 运行时执行后才能提供站点清单（见 docs/js2p宿主契约.md）"]
        )
    }

    /// 取远端 32 字节摘要；地址缺失返回 nil。
    func fetchDigest(_ url: URL?) async throws -> String? {
        guard let url else {
            return nil
        }
        let response = try await transport.send(HTTPRequest(url: url, timeout: 15))
        guard response.isSuccess else {
            throw CatVodError.network(status: response.status, url: url.absoluteString, reason: "摘要文件获取失败")
        }
        return String(data: response.body, encoding: .utf8) ?? ""
    }
}
