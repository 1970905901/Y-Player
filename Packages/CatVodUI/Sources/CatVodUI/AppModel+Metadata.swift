import CatVodNet
import CatVodSource
import Foundation

extension AppModel {
    /// TMDB 配置（Emby 视图那一层）：**读写都走注入的 `defaults`**，与其它设置同一条路。
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
    /// 三条约定（「M11 Emby 视图」待做第 1 片定过）：
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
            let results = try await client.search(title)
            guard let found = results.first else {
                return .notFound
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
