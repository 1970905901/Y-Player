import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import Combine
import Foundation
import SwiftUI

/// 应用主状态。
///
/// 职责：持有「配置来源 → 站点清单 → 各站点客户端」的状态，并做展示层需要的一切决策：
/// 哪些站点可用、哪些不可用及原因、当前播放内核（含降级原因）。
///
/// 说明：iOS 15 / macOS 13 下限下使用 `ObservableObject`（`@Observable` 需 iOS 17+，
/// 按 `docs/UI 规范.md` 不得为统一观感而抬高下限）。
@MainActor
public final class AppModel: ObservableObject {
    /// 配置加载状态。
    public enum LoadState: Sendable {
        case idle
        case loading
        case loaded(LoadedSource)
        case failed(String)

        public var isLoading: Bool {
            if case .loading = self {
                return true
            }
            return false
        }

        public var loadedSource: LoadedSource? {
            if case let .loaded(source) = self {
                return source
            }
            return nil
        }

        public var failureReason: String? {
            if case let .failed(reason) = self {
                return reason
            }
            return nil
        }
    }

    // MARK: - 持久化键

    private enum StorageKey {
        static let configURL = "yplayer.configURL"
        static let preferredEngine = "yplayer.preferredEngine"
        static let decoderMode = "yplayer.decoderMode"
    }

    // MARK: - 输出状态

    @Published public private(set) var state: LoadState = .idle
    @Published public var configURL: String {
        didSet {
            UserDefaults.standard.set(configURL, forKey: StorageKey.configURL)
        }
    }

    /// 播放内核：由用户在设置里**手动选择**，不自动切换。
    @Published public var preferredEngine: PlayerEngineKind {
        didSet {
            UserDefaults.standard.set(preferredEngine.rawValue, forKey: StorageKey.preferredEngine)
            refreshPlaybackNotice()
        }
    }

    /// 解码方式（硬解/软解）：由用户手动选择，不自动切换。
    @Published public var decoderMode: DecoderMode {
        didSet {
            UserDefaults.standard.set(decoderMode.rawValue, forKey: StorageKey.decoderMode)
            refreshPlaybackNotice()
        }
    }

    /// 设置页提示：所选内核不可用、解码方式对所选内核无效等（如实告知，不静默处理）。
    @Published public private(set) var playbackNotice: String = ""

    /// 当前播放设置。
    public var playbackSettings: PlaybackSettings {
        PlaybackSettings(engine: preferredEngine, decoderMode: decoderMode)
    }

    // MARK: - 依赖

    private let cacheDirectory: URL
    private let sessionTransport: URLSessionTransport
    /// 详情缓存（进程内共享）。
    private let detailCache = DetailCache()

    public init(cacheDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = cacheDirectory ?? Self.defaultCacheDirectory()
        self.cacheDirectory = base
        sessionTransport = URLSessionTransport()

        configURL = defaults.string(forKey: StorageKey.configURL) ?? ""
        let storedEngine = defaults.string(forKey: StorageKey.preferredEngine)
        preferredEngine = storedEngine.flatMap(PlayerEngineKind.init(rawValue:)) ?? .system
        let storedDecoder = defaults.string(forKey: StorageKey.decoderMode)
        decoderMode = storedDecoder.flatMap(DecoderMode.init(rawValue:)) ?? .hardware
        refreshPlaybackNotice()
    }

    // MARK: - 配置

    /// 当前配置里可用的站点（已剔除隐藏与不可用项）。
    public var sites: [Site] {
        state.loadedSource?.config.usableSites ?? []
    }

    /// 全部站点（含不可用，界面需要展示原因）。
    public var allSites: [Site] {
        state.loadedSource?.config.visibleSites ?? []
    }

    /// 配置告警（含站点不可用原因、离线回退提示）。
    public var warnings: [String] {
        state.loadedSource?.warnings ?? []
    }

    public var loadedKind: LoadedSource.Kind? {
        state.loadedSource?.kind
    }

    /// 加载配置。
    public func load(forceRefresh: Bool = false) async {
        let target = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            state = .failed("请先填写配置地址（支持猫源 JSON 或 js2p 的 index.js）")
            return
        }
        state = .loading

        let transport = transportForConfiguration()
        let repository = SourceRepository(transport: transport, cacheDirectory: cacheDirectory)
        do {
            let loaded = try await repository.load(configURL: target, forceRefresh: forceRefresh)
            state = .loaded(loaded)
            // 配置已变更：缓存里的详情可能对应旧站点/旧线路，直接清空。
            await detailCache.invalidateAll()
            // 接口缓存自愈：按容量上限淘汰最旧的（当前接口的缓存不动）。
            enforceSourceCacheLimit()
        } catch let error as CatVodError {
            state = .failed(error.errorDescription ?? "加载失败")
        } catch {
            state = .failed(error.localizedDescription)
        }
        refreshPlaybackNotice()
    }

    /// 为站点请求构造传输层：把配置里的 `headers` 与 `ads` 规则带进去。
    public func transportForConfiguration() -> HTTPTransport {
        guard let config = state.loadedSource?.config else {
            return sessionTransport
        }
        return URLSessionTransport(configuration: URLSessionTransport.Configuration(config: config))
    }

    /// 站点客户端（CMS 通道）。
    public func makeCMSClient() -> CMSClient {
        CMSClient(transport: transportForConfiguration())
    }

    /// 列表补图（best-effort）：首页 / 分类 / 搜索拿到列表后按需补封面。
    public func makePictureFiller() -> PictureFiller {
        PictureFiller(client: makeCMSClient())
    }

    /// 接口（源配置）缓存管理。
    ///
    /// 与 ``detailCache``（详情缓存）区分：这里管的是**落盘的源配置**（JSON 文本、js2p 的 6 MB bundle 与 `.md5`）。
    public var sourceCache: SourceCacheStore {
        SourceCacheStore(directory: cacheDirectory)
    }

    /// 接口缓存概览（接口管理页展示）；目录不可读时返回 nil。
    public func sourceCacheSummary() -> SourceCacheStore.Summary? {
        try? sourceCache.summary(currentURL: currentSourceURL())
    }

    /// 清空接口缓存，返回删除的文件数。
    @discardableResult
    public func clearSourceCache() -> Int {
        (try? sourceCache.clear()) ?? 0
    }

    /// 清掉非当前接口的缓存残留（换接口后每个 JS 源会残留 ≈ 6 MB），返回删除的文件数。
    @discardableResult
    public func pruneOrphanSourceCaches() -> Int {
        (try? sourceCache.pruneOrphans(currentURL: currentSourceURL())) ?? 0
    }

    /// 当前配置地址对应的 URL（用于区分「当前接口的缓存」与「残留」）。
    ///
    /// 内联 JSON 没有 URL：此时全部缓存都算残留（符合预期——用户已改用内联配置）。
    private func currentSourceURL() -> URL? {
        ConfigLocator.locate(configURL.trimmingCharacters(in: .whitespacesAndNewlines))?.url
    }

    /// 容量上限自愈：超过 64 MB 时淘汰最旧的缓存，**不会删除当前接口的缓存**。
    private func enforceSourceCacheLimit() {
        try? sourceCache.enforceLimit(currentURL: currentSourceURL())
    }

    /// 详情获取（带缓存）。
    ///
    /// 共享同一个 ``DetailCache``：详情页在「列表 → 详情 → 返回 → 再进」之间复用结果；
    /// `type=3` 的设置类 / Spider 站点由缓存内部挡板直接跳过（见 `DetailCache.shouldCache`）。
    public func makeDetailProvider() -> DetailProvider {
        DetailProvider(client: makeCMSClient(), cache: detailCache)
    }

    /// js2p 通道客户端：本地 Node 服务就绪后传入 baseURL（M1.6 落地）。
    public func makeCatSpiderClient(baseURL: URL) -> CatSpiderHTTPClient? {
        CatSpiderHTTPClient(
            baseURL: baseURL,
            transport: transportForConfiguration()
        )
    }

    /// 严格解析播放内核（**不降级**）：不可用时返回原因，由 UI 提示用户修改设置。
    public func resolvePlayback() -> PlayerEngineResolution {
        PlayerCoordinator().resolve(settings: playbackSettings)
    }

    private func refreshPlaybackNotice() {
        if case .javaScript = state.loadedSource?.kind {
            playbackNotice = "当前是 JS 源（js2p）：站点清单需等内嵌 Node 服务就绪后加载（M1.6）"
            return
        }
        var notes: [String] = []
        if case let .unavailable(_, reason) = resolvePlayback() {
            notes.append(reason)
        }
        if !playbackSettings.isDecoderModeEffective {
            notes.append("\(decoderMode.displayName)对\(preferredEngine.displayName)无效：系统播放器由系统自行决定解码方式")
        }
        playbackNotice = notes.joined(separator: "\n")
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("YPlayer/Sources", isDirectory: true)
    }
}
