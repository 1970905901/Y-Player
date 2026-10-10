import CatVodNet
import CatVodSource
import Foundation

extension AppModel {
    /// TMDB 配置（TMDB 视图那一层）：**读写都走注入的 `defaults`**，与其它设置同一条路。
    ///
    /// 做成计算属性是有意的：**不用动 `init` 里那一串装载代码** —— 谁读谁从盘上取，
    /// 谁写谁立刻落盘（「用户动作即落盘」的口径不变）。
    ///
    /// 全空时把键**删掉**而不是写一个空串：盘上不留「有键但没值」这种需要人肉眼判断的状态。
    var tmdbConfig: TMDBConfig {
        get {
            TMDBConfig(storageString: defaults.string(forKey: Self.tmdbConfigDefaultsKey) ?? "")
        }
        set {
            let encoded = newValue.storageString
            if encoded.replacingOccurrences(of: "|", with: "").isEmpty {
                defaults.removeObject(forKey: Self.tmdbConfigDefaultsKey)
            } else {
                defaults.set(encoded, forKey: Self.tmdbConfigDefaultsKey)
            }
        }
    }

    /// 「这一层能不能用」：只是 `TMDBConfig.isConfigured` 的透传，放在这里让界面少认识一个类型。
    var isTMDBConfigured: Bool {
        tmdbConfig.isConfigured
    }

    /// 取图模式（固定 / 随机 / 轮播）：**顶部与选集卡片共用同一套**（见 ``PosterPicker``）。
    ///
    /// 与其它偏好同一条路：读写在注入的 `defaults` 上，用户改一次落一次盘。
    /// 值不认识就回落 `.fixed`（旧版本写进去的值、或手改过的串，都不该让界面空着）。
    var tmdbPosterMode: PosterMode {
        get {
            defaults.string(forKey: Self.tmdbPosterModeDefaultsKey)
                .flatMap(PosterMode.init(rawValue:)) ?? .fixed
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.tmdbPosterModeDefaultsKey)
        }
    }

    private static let tmdbConfigDefaultsKey = "tmdb.config"
    private static let tmdbPosterModeDefaultsKey = "tmdb.posterMode"
    private static let tmdbScrapeDefaultsKey = "tmdb.scrape"

    /// 元信息刮削总开关（详情页「⋯」菜单里那一项）。
    ///
    /// **默认开**（参考视频里就是「元信息刮削：开」）；关掉整层不工作、用站点数据 ——
    /// 除了省流量，也是给「刮错了、我不想要」留的一条退路。
    var tmdbScrapeEnabled: Bool {
        get { defaults.object(forKey: Self.tmdbScrapeDefaultsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.tmdbScrapeDefaultsKey) }
    }

    /// 要这一片的 TMDB 元信息与**已建好的取图集**（详情页顶部 / 选集卡片共用；M11）。
    ///
    /// 三条约定（M11 待做第 1 片时定过）：
    /// 1. **缓存按片名**，命中条件是「片名相同**且**取图模式相同」—— 缓存的是建好的
    ///    ``TMDBPosterSet``，它带着模式；换模式必须重建（低频操作，多一次请求可接受）；
    /// 2. **并发合流**：同一「模式 + 片名」同时被多处要时只发一轮请求；
    /// 3. **不做 TTL**：进程内会话缓存，重启就没了；要强制重刮就关一下刮削总开关再打开。
    func tmdbBundle(for title: String, mode: PosterMode) async -> TMDBMetadataOutcome {
        guard tmdbScrapeEnabled else {
            return .disabled
        }
        guard isTMDBConfigured else {
            return .notConfigured
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notFound
        }
        if let cached = tmdbBundleCache[title], cached.mode == mode {
            return .found(cached)
        }
        let key = "\(mode.rawValue)|\(title)"
        if let inflight = tmdbBundleInflight[key] {
            return await inflight.value
        }
        let task = Task { await performTMDBLookup(title: title, mode: mode) }
        tmdbBundleInflight[key] = task
        let outcome = await task.value
        tmdbBundleInflight[key] = nil
        if case let .found(bundle) = outcome {
            tmdbBundleCache[title] = bundle
        }
        return outcome
    }

    /// 真正发请求的那一半：只被 ``tmdbBundle(for:mode:)`` 调（不进缓存、不做合流）。
    private func performTMDBLookup(title: String, mode: PosterMode) async -> TMDBMetadataOutcome {
        do {
            let client = TMDBClient(config: tmdbConfig, transport: tmdbTransportOverride ?? URLSessionTransport())
            // 手动匹配优先（M11 片 5）：用户指定了就取那一条，**不再搜** ——
            // 这一层存在的意义正是「自动搜出来的不是我要的」。
            let found: TMDBMetadata
            if let match = tmdbMatchKey(for: title) {
                found = try await client.details(kind: match.kind, id: match.id)
            } else {
                let results = try await client.search(title)
                guard let first = results.first else {
                    return .notFound
                }
                found = first
            }
            let fetched = try? await client.backdrops(kind: found.kind, id: found.id)
            let backdrops = fetched ?? []
            let posterSet = TMDBPosterSet(
                metadata: found,
                backdrops: backdrops,
                config: tmdbConfig,
                mode: mode
            )
            return .found(TMDBBundle(metadata: found, posterSet: posterSet, mode: mode))
        } catch {
            return .failed(userFacingMessage(error))
        }
    }

    /// 这一片有没有手动匹配。片名按**去空白**归一 —— 与表的键（``TMDBMatchBook/setKey(_:for:)``）一致。
    func tmdbMatchKey(for title: String) -> TMDBMatchKey? {
        tmdbMatchBook.key(for: title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 这一片现在走的是哪条路：`auto`（自动搜）或 `movie:123`。
    ///
    /// 用途是**当加载键**：详情页顶部与选集卡片两个 `.task(id:)` 都把它拼进键里，
    /// 手动匹配一改，两处各自重拉 —— 不用谁去通知谁。
    func tmdbMatchToken(for title: String) -> String {
        tmdbMatchKey(for: title)?.storageToken ?? "auto"
    }

    /// 手动匹配表（M11 片 5）：片名 → 指定 TMDB 条目。落盘在注入的 `defaults` 上，与 `tmdbConfig` 同一条路。
    var tmdbMatchBook: TMDBMatchBook {
        get {
            TMDBMatchBook(storageString: defaults.string(forKey: Self.tmdbMatchDefaultsKey) ?? "")
        }
        set {
            let encoded = newValue.storageString
            if encoded.isEmpty {
                defaults.removeObject(forKey: Self.tmdbMatchDefaultsKey)
            } else {
                defaults.set(encoded, forKey: Self.tmdbMatchDefaultsKey)
            }
        }
    }

    /// 手动指定 / 恢复自动匹配（`key` 传 nil 就是恢复），并**当场作废这一片的会话缓存**：
    /// 下一次读（加载键一变就会读）走新匹配，而不是复用旧结果。
    ///
    /// 在途请求一并丢掉：那一轮用的是旧匹配，结果不该盖在新选择上。
    func setTMDBMatchKey(_ key: TMDBMatchKey?, for title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var book = tmdbMatchBook
        book.setKey(key, for: trimmed)
        tmdbMatchBook = book
        tmdbBundleCache[title] = nil
        tmdbBundleCache[trimmed] = nil
        tmdbBundleInflight = tmdbBundleInflight.filter { !$0.key.hasSuffix("|\(trimmed)") }
    }

    /// 「手动匹配」面板用：按用户输入搜 TMDB，返回候选（电影与剧集一起给）。
    ///
    /// 不走 ``tmdbBundle(for:mode:)``：那个是「按片名取整片结果」，这一步是**挑选**，
    /// 要的就是原始候选列表（含 id 与类型），也不该写进缓存。
    func tmdbSearchCandidates(_ query: String) async throws -> [TMDBMetadata] {
        let client = TMDBClient(config: tmdbConfig, transport: tmdbTransportOverride ?? URLSessionTransport())
        return try await client.search(query)
    }

    private static let tmdbMatchDefaultsKey = "tmdb.matches"
}

/// 一次刮削的产物：元信息 + **已建好的取图集** + 建它时的取图模式（缓存命中要连着模式一起对）。
struct TMDBBundle: Sendable {
    let metadata: TMDBMetadata
    let posterSet: TMDBPosterSet
    let mode: PosterMode
}

/// 「要这一片的元信息」的结果：拿到了就 `found`，没拿到把原因说清 —— 界面据此显示三态，不静默。
enum TMDBMetadataOutcome: Sendable {
    case found(TMDBBundle)
    case disabled
    case notConfigured
    case notFound
    case failed(String)
}
