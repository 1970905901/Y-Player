import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import CatVodStore
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

    // MARK: - js2p 宿主（JS 源）

    /// 宿主状态：界面据此显示「不可用 / 启动中 / 运行中 / 失败」，而不是一句笼统的占位文案。
    @Published public private(set) var hostStatus: JS2PHostStatus = .idle

    /// 宿主提供的站点。
    ///
    /// JS 源时这是站点的**唯一**来源：`LoadedSource.config` 是空配置（站点清单要由 Node 执行后给出）。
    @Published public private(set) var hostSites: [Site] = []

    /// 宿主会话（非 JS 源时为空）。
    private var js2pHost: JS2PHostService?

    /// js2p 站点的一次性 `POST /init` 记忆。
    ///
    /// **必须由 AppModel 持有**：`makeSiteClient()` 每次都会新建一个 `SiteClient`，
    /// 若让每个 `SiteClient` 自带一份记忆，就变成「每次动作都 init」
    /// （参考实现 `CatSpider.java` 是每个 spider 实例只 init 一次）。
    private let spiderInitializer = CatSpiderInitializer()

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
        progressStore = InMemoryPlaybackProgressStore()

        configURL = defaults.string(forKey: StorageKey.configURL) ?? ""
        let storedEngine = defaults.string(forKey: StorageKey.preferredEngine)
        preferredEngine = storedEngine.flatMap(PlayerEngineKind.init(rawValue:)) ?? .system
        let storedDecoder = defaults.string(forKey: StorageKey.decoderMode)
        decoderMode = storedDecoder.flatMap(DecoderMode.init(rawValue:)) ?? .hardware
        refreshPlaybackNotice()
    }

    // MARK: - 配置

    /// 当前可用的站点。
    ///
    /// JS 源（js2p）的站点来自内嵌 Node 宿主；其余配置来自 `LoadedSource.config`。
    /// 「可用」对宿主站点按 `Site.availability` 判定（与配置站点同一口径）。
    public var sites: [Site] {
        if !hostSites.isEmpty {
            return hostSites.filter(\.availability.isAvailable)
        }
        return state.loadedSource?.config.usableSites ?? []
    }

    /// 全部站点（含不可用，界面需要展示原因）。
    public var allSites: [Site] {
        hostSites.isEmpty ? (state.loadedSource?.config.visibleSites ?? []) : hostSites
    }

    /// 配置告警（含站点不可用原因、离线回退提示）。
    public var warnings: [String] {
        state.loadedSource?.warnings ?? []
    }

    public var loadedKind: LoadedSource.Kind? {
        state.loadedSource?.kind
    }

    // MARK: - 站点清单版本

    /// 站点清单版本号：每完成一次「配置加载 / 宿主站点刷新 / 宿主停止」就自增。
    ///
    /// 为什么需要它：`TabView` 里的首页是**常驻**视图，`.task` 在回到该 Tab 时不一定重跑；
    /// 而它重跑时 `loadHome()` 又会因为已有分类直接返回 —— 首页对「接口换了」完全没有反应，
    /// 旧行为只能靠**杀进程冷启动**才看到新接口的站点。界面监听这个版本号自行作废并重载，
    /// 详见 `docs/任务记录/M02P9-接口变更后的自动刷新.md`。
    @Published public private(set) var siteCatalogRevision: Int = 0

    /// 通知界面「站点清单可能已经整体换过」。
    ///
    /// 多调一次是安全的：界面按版本号去重（版本号没变就不动），所以嵌套调用点不必精心安排。
    private func bumpSiteCatalogRevision() {
        siteCatalogRevision += 1
    }

    /// 加载配置。
    public func load(forceRefresh: Bool = false) async {
        let target = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            state = .failed("请先填写配置地址（支持猫源 JSON 或 js2p 的 index.js）")
            bumpSiteCatalogRevision()
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
            // JS 源：站点清单不在配置里，必须由内嵌 Node 宿主提供（macOS 可用，iOS 待 libnode）。
            await refreshHost(for: loaded, forceRestart: forceRefresh)
        } catch let error as CatVodError {
            state = .failed(error.errorDescription ?? "加载失败")
        } catch {
            state = .failed(error.localizedDescription)
        }
        refreshPlaybackNotice()
        // 站点清单可能已经整体换过（新接口 / 宿主新站点 / 加载失败后清空）：通知界面作废旧内容并重载。
        bumpSiteCatalogRevision()
    }

    /// 冷启动恢复：本地保存了配置地址、且本进程这次还没加载过任何配置时，自动加载一次。
    ///
    /// 为什么需要：`configURL` 是持久化的，但以前**只有用户手动点「加载」**才会真的去取配置 ——
    /// 于是每次冷启动首页都是空的，得先去「接口管理」再点一次加载（这也是「首页要重新加载」的一半原因）。
    /// 行为与手动加载完全一致：JS 源只多取一次 `index.js.md5`，JSON 源网络失败仍退回本地缓存并提示。
    public func loadSavedSourceIfNeeded() async {
        // 只在「这次进程还没开始」时恢复：不覆盖用户正在进行的操作，也不自动重试刚失败的结果。
        guard case .idle = state else {
            return
        }
        guard !configURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        await load()
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

    /// 站点客户端门面：按站点类型分发（CMS / CatSpider HTTP）。
    ///
    /// 界面统一用这个：JS 源站点是 `type=3`，`CMSClient` 会直接抛 `unsupported`。
    public func makeSiteClient() -> SiteClient {
        SiteClient(transport: transportForConfiguration(), initializer: spiderInitializer)
    }

    // MARK: - js2p 宿主

    /// 按加载结果维护宿主：JS 源启动/刷新，其它源停止。
    private func refreshHost(for source: LoadedSource, forceRestart: Bool) async {
        guard source.kind == .javaScript, let scriptURL = source.cachedURL else {
            await stopHost()
            return
        }
        guard JS2PHostService.isRuntimeAvailable else {
            hostSites = []
            js2pHost = nil
            hostStatus = .unavailable(reason: JS2PHostService.runtimeUnavailableReason)
            return
        }

        hostStatus = .starting
        let service = js2pHost ?? JS2PHostService(transport: sessionTransport, scriptURL: scriptURL)
        js2pHost = service
        do {
            let snapshot = try await service.sites(forceRestartHost: forceRestart)
            hostSites = snapshot.sites
            let baseURL = await service.currentBaseURL()
            hostStatus = .running(
                baseURL: baseURL?.absoluteString ?? "",
                siteCount: snapshot.sites.count,
                disabledSiteCount: snapshot.disabledSiteCount
            )
            // 站点集合变了：旧详情可能属于别的站点，不能复用。
            await detailCache.invalidateAll()
        } catch {
            hostSites = []
            hostStatus = .failed(reason: userFacingMessage(error))
        }
    }

    /// 重启宿主（接口页按钮）。
    public func restartHost() async {
        guard let source = state.loadedSource, source.kind == .javaScript else {
            return
        }
        await refreshHost(for: source, forceRestart: true)
        // 宿主重启会换掉站点清单（端口、站点集合都可能变）：首页/搜索据此作废旧内容。
        bumpSiteCatalogRevision()
    }

    /// 停止宿主并清空宿主站点。
    public func stopHost() async {
        await js2pHost?.stop()
        js2pHost = nil
        hostSites = []
        hostStatus = .idle
        bumpSiteCatalogRevision()
    }

    /// 宿主最近输出（诊断用；失败时界面可展开查看，避免「为什么没有站点」只能靠猜）。
    public func hostDiagnostics(limit: Int = 20) async -> [String] {
        guard let service = js2pHost else {
            return []
        }
        return await service.recentOutput(limit: limit)
    }

    /// 列表补图（best-effort）：首页 / 分类 / 搜索拿到列表后按需补封面。
    public func makePictureFiller() -> PictureFiller {
        PictureFiller(client: makeCMSClient())
    }

    /// 换源服务：按片名在其它站点搜索候选（`changeable == 0` 与本平台不可用的站点会被跳过）。
    public func makeChangeSourceService() -> ChangeSourceService {
        ChangeSourceService(client: makeSiteClient())
    }

    /// 播放进度存储。
    ///
    /// M2 用内存实现（进程内有效）；M8 用 GRDB 落库时只需替换 ``progressStore`` 的构造，
    /// 详情页与播放页按协议编写、不感知底层实现。
    public let progressStore: PlaybackProgressStore

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
        // `try?` 会把 @discardableResult 变成 `Int?`，必须显式丢弃，否则是「结果未使用」警告。
        _ = try? sourceCache.enforceLimit(currentURL: currentSourceURL())
    }

    /// 详情获取（带缓存）。
    ///
    /// 共享同一个 ``DetailCache``：详情页在「列表 → 详情 → 返回 → 再进」之间复用结果；
    /// `type=3` 的设置类 / Spider 站点由缓存内部挡板直接跳过（见 `DetailCache.shouldCache`）。
    public func makeDetailProvider() -> DetailProvider {
        DetailProvider(client: makeSiteClient(), cache: detailCache)
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
            // JS 源的站点由内嵌 Node 宿主提供（macOS 可用）：宿主失败的原因在「接口管理 → Node 宿主」里显示，
            // 不再用一句「等 M1.6」把所有情况盖住。
            playbackNotice = ""
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
