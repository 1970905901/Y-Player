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
        static let homeLayout = "yplayer.homeLayout"
        static let localProxyEnabled = "yplayer.localProxyEnabled"
        static let syncIdentifier = "yplayer.syncIdentifier"
        static let sourceCacheLifetime = "yplayer.sourceCacheLifetime"
        static let homeCacheLifetime = "yplayer.homeCacheLifetime"
        static let playbackPageLayout = "yplayer.playbackPageLayout"
        static let autoPlayFirstEpisode = "yplayer.autoPlayFirstEpisode"
        static let danmakuAPI = "yplayer.danmakuAPI"
        static let engineLogEnabled = "yplayer.engineLogEnabled"
        static let searchHistory = "yplayer.searchHistory"
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

    /// 首页展示方式（设置 → 首页 → 展示方式）：纵向列表 / 横向海报网格。
    ///
    /// 与内核/解码方式同一套做法：**用户手动选择 + 落 `UserDefaults`**，不随数据自动变化。
    @Published public var homeLayout: HomeLayout {
        didSet {
            UserDefaults.standard.set(homeLayout.rawValue, forKey: StorageKey.homeLayout)
        }
    }

    // MARK: - 缓存有效期（设置 → 数据 → 缓存管理）

    /// 源缓存时间：接口配置在有效期内**直接读本地、不联网**（参考图默认「12小时」）。
    ///
    /// 生效点在 ``load(forceRefresh:)``：过期或用户手动强制刷新时才走网络。
    @Published public var sourceCacheLifetime: CacheLifetime {
        didSet {
            UserDefaults.standard.set(sourceCacheLifetime.rawValue, forKey: StorageKey.sourceCacheLifetime)
        }
    }

    /// 首页缓存时间：首页/分类结果在有效期内直接读落盘缓存（参考图默认「7天」）。
    ///
    /// 生效点在 `HomeView+Data.swift`（读缓存命中就不发请求）。
    @Published public var homeCacheLifetime: CacheLifetime {
        didSet {
            UserDefaults.standard.set(homeCacheLifetime.rawValue, forKey: StorageKey.homeCacheLifetime)
        }
    }

    // MARK: - 播放页与播放器（设置 → 播放）

    /// 播放页显示视图（精简视图 / Emby 视图）：详情页换排布，数据与交互都不变。
    @Published public var playbackPageLayout: PlaybackPageLayout {
        didSet {
            UserDefaults.standard.set(playbackPageLayout.rawValue, forKey: StorageKey.playbackPageLayout)
        }
    }

    /// 自动播放：首次进入详情页是否自动选中第一集开始播放（参考图副标题的原文语义）。
    ///
    /// 生效点在 `VodDetailView`：详情加载完成后按它决定是否自动进入第一集；
    /// 有「上次看到」的进度时以续播为准，不会把用户从上次位置拽回第一集。
    @Published public var autoPlayFirstEpisode: Bool {
        didSet {
            UserDefaults.standard.set(autoPlayFirstEpisode, forKey: StorageKey.autoPlayFirstEpisode)
        }
    }

    // MARK: - 弹幕 API（设置 → 播放 → 弹幕 API）

    /// 弹幕 API 配置：启用开关 + 四个地址槽位。
    ///
    /// 参考图里它的副标题写明「开启后将禁用视频源的弹幕功能」——
    /// 弹幕的请求链与渲染属于 M8，本里程碑只把地址**真实保存**下来（页内如实说明）。
    @Published public var danmakuAPI: DanmakuAPIConfig {
        didSet {
            UserDefaults.standard.set(danmakuAPI.persistenceValue, forKey: StorageKey.danmakuAPI)
        }
    }

    // MARK: - 搜索历史（搜索页）

    /// 搜索历史：最近的在前，最多 `SearchHistory.limit` 条。
    ///
    /// 与其它设置一样「用户动作即落盘」（UserDefaults），重启后仍在。
    /// 规则（去重置顶 / 封顶 / 坏存档当空）在 `SearchHistory` 里，单测覆盖。
    @Published public var searchHistory: [String] {
        didSet {
            UserDefaults.standard.set(SearchHistory.encode(searchHistory), forKey: StorageKey.searchHistory)
        }
    }

    /// 记一次搜索（回车提交、或点历史里的某一条）。
    ///
    /// 内容没变化就不写盘，避免每次搜索都触发一次 UserDefaults 写入。
    public func rememberSearch(_ keyword: String) {
        let updated = SearchHistory.adding(keyword, to: searchHistory)
        if updated != searchHistory {
            searchHistory = updated
        }
    }

    /// 清空搜索历史（搜索页历史区右侧的 🗑）。
    public func clearSearchHistory() {
        if !searchHistory.isEmpty {
            searchHistory = []
        }
    }

    // MARK: - 引擎日志（设置 → 数据 → 日志管理）

    /// 引擎日志开关：控制宿主（js2p / libnode）输出是否**落盘**（参考图默认关）。
    ///
    /// 开启后宿主输出会写入日志文件，可配合「导出」带走现场；
    /// 关闭时只保留内存里的最近若干行（诊断仍可用，不占磁盘）。
    @Published public var isEngineLogEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEngineLogEnabled, forKey: StorageKey.engineLogEnabled)
            applyLogPreferenceToHost()
        }
    }

    // MARK: - 本地代理（M6）

    /// 播放是否走本机代理注入 header（设置 → 播放 → 本地代理）。
    ///
    /// 默认为开：多数源要求 HLS 的子清单/分片/密钥也带 `Referer` 等 header，
    /// 而系统播放器只能给主请求设 header（细节见 `docs/任务记录/M06a-本地HTTP服务与本地代理.md`）。
    @Published public var isLocalProxyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLocalProxyEnabled, forKey: StorageKey.localProxyEnabled)
            refreshPlaybackNotice()
        }
    }

    /// 本机服务的状态说明（端口 / 失败原因）：设置页如实展示，不静默失败。
    ///
    /// setter 是 `internal(set)` 而不是 `private(set)`：写入点在**同模块的扩展文件**
    /// `AppModel+LocalProxy.swift` 里，`private(set)` 只对声明所在文件开放，跨文件赋值会编译失败
    /// （CI 报过 `cannot assign to property: 'localProxyNotice' setter is inaccessible`）。
    @Published public internal(set) var localProxyNotice: String = ""

    /// 本机服务端口；未启动为 nil。
    ///
    /// 在 AppModel 里留一份而不是每次去问 actor：``proxiedMediaResource(_:)`` 是**同步**判定，
    /// 而 `LocalHTTPServer.port` 是 actor 属性，读它必须 await。
    ///
    /// setter 理由同 ``localProxyNotice``：启停逻辑在 `AppModel+LocalProxy.swift`。
    @Published public internal(set) var localProxyPort: UInt16?

    /// 本地代理服务实例；由 ``ensureLocalServer()`` 创建并启动（见 `AppModel+LocalProxy.swift`）。
    var localServer: LocalHTTPServer?

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

    /// 缓存根目录：接口缓存直接落在它下面（`SourceCacheStore`），首页缓存在 `Home/` 子目录。
    ///
    /// 可见性是「模块内」而不是 `private`：``AppModel+Cache`` 扩展文件要按它推导首页缓存目录
    /// （`private` 只对声明所在文件开放，跨文件读会编译失败）。
    let cacheDirectory: URL
    private let sessionTransport: URLSessionTransport
    /// 详情缓存（进程内共享）。
    private let detailCache = DetailCache()

    public init(cacheDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = cacheDirectory ?? Self.defaultCacheDirectory()
        self.cacheDirectory = base
        sessionTransport = URLSessionTransport()
        // 存储：优先 GRDB 落库（M08b）；打开失败退回内存实现并如实说明（不许静默）。
        // 这里只替换构造：两个 store 都是协议类型，详情页 / 追剧页 / 播放页一行都不用改。
        let storage = Self.openStorageDatabase()
        storageDatabase = storage
        if let storage {
            progressStore = GRDBPlaybackProgressStore(database: storage)
            favoriteStore = GRDBFavoriteStore(database: storage)
        } else {
            progressStore = InMemoryPlaybackProgressStore()
            favoriteStore = InMemoryFavoriteStore()
            storageNotice = "打开本地数据库失败：本次运行的收藏与播放进度只存在内存里，重启即丢。"
        }

        configURL = defaults.string(forKey: StorageKey.configURL) ?? ""
        let storedEngine = defaults.string(forKey: StorageKey.preferredEngine)
        preferredEngine = storedEngine.flatMap(PlayerEngineKind.init(rawValue:)) ?? .system
        let storedDecoder = defaults.string(forKey: StorageKey.decoderMode)
        decoderMode = storedDecoder.flatMap(DecoderMode.init(rawValue:)) ?? .hardware
        let storedLayout = defaults.string(forKey: StorageKey.homeLayout)
        homeLayout = storedLayout.flatMap(HomeLayout.init(rawValue:)) ?? .vertical
        isLocalProxyEnabled = defaults.object(forKey: StorageKey.localProxyEnabled) as? Bool ?? true
        localSyncIdentifier = Self.storedSyncIdentifier(defaults: defaults)

        // 缓存有效期：默认值与参考图一致（源 12 小时、首页 7 天）。
        let storedSourceLifetime = defaults.string(forKey: StorageKey.sourceCacheLifetime)
        sourceCacheLifetime = storedSourceLifetime.flatMap(CacheLifetime.init(rawValue:)) ?? .hours12
        let storedHomeLifetime = defaults.string(forKey: StorageKey.homeCacheLifetime)
        homeCacheLifetime = storedHomeLifetime.flatMap(CacheLifetime.init(rawValue:)) ?? .days7

        // 播放页与播放器：默认精简视图、不自动播放（与参考图的初始状态一致）。
        let storedPlaybackLayout = defaults.string(forKey: StorageKey.playbackPageLayout)
        playbackPageLayout = storedPlaybackLayout.flatMap(PlaybackPageLayout.init(rawValue:)) ?? .compact
        autoPlayFirstEpisode = defaults.object(forKey: StorageKey.autoPlayFirstEpisode) as? Bool ?? false

        // 弹幕 API：默认未启用、四个槽位为空。
        danmakuAPI = DanmakuAPIConfig.decode(defaults.string(forKey: StorageKey.danmakuAPI))

        // 搜索历史：默认空（搜索页据此决定显示历史胶囊还是「还没有搜索记录」）。
        searchHistory = SearchHistory.decode(defaults.string(forKey: StorageKey.searchHistory) ?? "")

        // 引擎日志：默认关（与参考图的开关初始状态一致）。
        isEngineLogEnabled = defaults.object(forKey: StorageKey.engineLogEnabled) as? Bool ?? false
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
            let loaded = try await loadSource(target: target, forceRefresh: forceRefresh, repository: repository)
            state = .loaded(loaded)
            // 配置已变更：缓存里的详情可能对应旧站点/旧线路，直接清空。
            await detailCache.invalidateAll()
            // 接口缓存自愈：按容量上限淘汰最旧的（当前接口的缓存不动）。
            enforceSourceCacheLimit()
            // JS 源：站点清单不在配置里，必须由内嵌 Node 宿主提供（macOS 进程 / iOS libnode）。
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

    /// 取配置：先看「源缓存时间」——有效期内**直接用本地缓存、一次网络请求都不发**；
    /// 过期、没有缓存或用户手动强制刷新时才联网（见 `SourceRepository+FreshCache.swift`）。
    ///
    /// 缓存读坏（文件被截断、内容不再是合法配置）不算致命：吞掉错误继续联网，
    /// 不该因为一份坏缓存让用户打不开应用。
    private func loadSource(
        target: String,
        forceRefresh: Bool,
        repository: SourceRepository
    ) async throws -> LoadedSource {
        let maxAge = sourceCacheLifetime.timeInterval
        if !forceRefresh, let cached = try? await repository.loadCached(configURL: target, maxAge: maxAge) {
            return cached
        }
        return try await repository.load(configURL: target, forceRefresh: forceRefresh)
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
        let service = js2pHost ?? JS2PHostService(
            transport: sessionTransport,
            scriptURL: scriptURL,
            persistsHostOutput: isEngineLogEnabled
        )
        js2pHost = service
        // 开关可能在宿主启动之后被改过（设置 → 数据 → 日志管理）：每次刷新都对一次。
        await service.setLogPersistence(isEngineLogEnabled)
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

    /// 宿主落盘日志路径（没有落盘能力时为 nil）。
    ///
    /// 日志开关（``isEngineLogEnabled``）决定宿主是否把输出写文件；
    /// 「设置 → 数据 → 日志管理 → 导出」用它拿到要导出的内容。
    public func hostLogPath() async -> URL? {
        await js2pHost?.hostLogPath()
    }

    /// 宿主最近输出：内存里的尾部 + 落盘日志的尾部（见 ``JS2PHostService``）。
    ///
    /// 「源地址 → Node 宿主 → 查看宿主输出」与「设置 → 数据 → 日志管理」共用它；
    /// 没有宿主（未加载 JS 源 / 平台不支持）时返回空数组，界面据此显示「暂无输出」。
    public func hostDiagnostics(limit: Int = 20) async -> [String] {
        guard let host = js2pHost else {
            return []
        }
        return await host.hostDiagnostics(limit: limit)
    }

    /// 把日志开关应用到正在运行的宿主。
    ///
    /// 宿主不能重建（内嵌 node 每进程只能起一个实例），所以开关必须能**运行中改**；
    /// 宿主还没起来时什么都不做 —— 下次 ``refreshHost(for:forceRestart:)`` 会带上当前值。
    private func applyLogPreferenceToHost() {
        guard let host = js2pHost else {
            return
        }
        Task {
            await host.setLogPersistence(isEngineLogEnabled)
        }
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

    /// 收藏存储。
    ///
    /// 与 ``progressStore`` 同一套做法：M2 用内存实现（进程内有效），
    /// M8 换 GRDB 实现时只替换这里的构造，「追剧」页与详情页不改。
    public let favoriteStore: FavoriteStore

    /// 本地数据库（M08b）；nil 表示退回内存实现（设置页会如实说明，见 ``storageNotice``）。
    let storageDatabase: GRDBDatabase?

    /// 存储状态说明（落库路径 / 内存降级原因）。
    @Published public private(set) var storageNotice: String = ""

    /// 本机同步标识（设置 → iCloud 同步 里展示的那一串）。
    ///
    /// 只是**本机**的稳定标识：iCloud 同步尚未落地（先落库 M8，再谈同步），
    /// 但先把它生成并固定下来，将来启用同步时不必再换一套身份。
    public let localSyncIdentifier: String

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

    /// 本机同步标识：首次启动生成一次（`_` + 32 位十六进制），之后固定不变。
    private static func storedSyncIdentifier(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: StorageKey.syncIdentifier), !existing.isEmpty {
            return existing
        }
        let identifier = "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(identifier, forKey: StorageKey.syncIdentifier)
        return identifier
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("YPlayer/Sources", isDirectory: true)
    }
}
