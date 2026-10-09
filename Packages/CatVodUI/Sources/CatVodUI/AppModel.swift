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
    // 状态类型（`LoadState` / `LiveState`）见 `AppModel+States.swift` —— 类体只留「状态 + 存储 + init」，
    // 这样 `type_body_length` 才有余量（存储属性必须在类体里，类型声明放扩展即可）。

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
        static let danmakuDisplay = "yplayer.danmakuDisplay"
        static let subtitleDisplay = "yplayer.subtitleDisplay"
        static let engineLogEnabled = "yplayer.engineLogEnabled"
        static let searchHistory = "yplayer.searchHistory"
        static let liveSource = "yplayer.liveSource"
        static let liveGroup = "yplayer.liveGroup"
        static let liveKeep = "yplayer.liveKeep"
        static let liveFavorites = "yplayer.liveFavorites"
        static let liveEPGSetting = "yplayer.liveEPGSetting"
        static let livePassOverrides = "yplayer.livePassOverrides"
        static let siteGroupOrder = "yplayer.siteGroupOrder"
        static let siteNames = "yplayer.siteNames"
        static let siteGroupRules = "yplayer.siteGroupRules"
        static let discoverSiteKey = "yplayer.discoverSiteKey"
        static let searchSiteKey = "yplayer.searchSiteKey"
        static let searchExcludedSites = "yplayer.searchExcludedSites"
        static let hlsAdRuleOverrides = "yplayer.hlsAdRuleOverrides"
    }

    // MARK: - 输出状态

    @Published public private(set) var state: LoadState = .idle
    @Published public var configURL: String {
        didSet {
            defaults.set(configURL, forKey: StorageKey.configURL)
        }
    }

    /// 播放内核：由用户在设置里**手动选择**，不自动切换。
    @Published public var preferredEngine: PlayerEngineKind {
        didSet {
            defaults.set(preferredEngine.rawValue, forKey: StorageKey.preferredEngine)
            refreshPlaybackNotice()
        }
    }

    /// 解码方式（硬解/软解）：由用户手动选择，不自动切换。
    @Published public var decoderMode: DecoderMode {
        didSet {
            defaults.set(decoderMode.rawValue, forKey: StorageKey.decoderMode)
            refreshPlaybackNotice()
        }
    }

    /// 设置页提示：所选内核不可用、解码方式对所选内核无效等（如实告知，不静默处理）。
    ///
    /// setter 是 `internal(set)`：写入点在 `AppModel+Playback.swift` 的 `refreshPlaybackNotice`
    /// （`private(set)` 只对声明所在文件开放，跨文件写会编译失败）。
    @Published public internal(set) var playbackNotice: String = ""

    /// 最近一次读到的**播放信息**（分辨率 / 编码 / 色彩 / 实际硬解 / 丢帧），M17P2。
    ///
    /// 为什么放到 model 上：播放页里那份是 `@State`（只活在那个页面），而「这个人到底在播什么、
    /// 硬解有没有生效、丢了几帧」正是排查画质与卡顿要问的第一个问题 —— 复制诊断信息时得拿得到。
    /// 只在读到**非空**结果时由播放页回传（见 `notePlaybackStats(_:)`），读不到不该冲掉上一次。
    @Published public internal(set) var lastPlaybackStats: PlaybackStats?

    /// 首页展示方式（设置 → 首页 → 展示方式）：纵向列表 / 横向海报网格。
    ///
    /// 与内核/解码方式同一套做法：**用户手动选择 + 落 `UserDefaults`**，不随数据自动变化。
    @Published public var homeLayout: HomeLayout {
        didSet {
            defaults.set(homeLayout.rawValue, forKey: StorageKey.homeLayout)
        }
    }

    // MARK: - 缓存有效期（设置 → 数据 → 缓存管理）

    /// 源缓存时间：接口配置在有效期内**直接读本地、不联网**（参考图默认「12小时」）。
    ///
    /// 生效点在 ``load(forceRefresh:)``：过期或用户手动强制刷新时才走网络。
    @Published public var sourceCacheLifetime: CacheLifetime {
        didSet {
            defaults.set(sourceCacheLifetime.rawValue, forKey: StorageKey.sourceCacheLifetime)
        }
    }

    /// 首页缓存时间：首页/分类结果在有效期内直接读落盘缓存（参考图默认「7天」）。
    ///
    /// 生效点在 `HomeView+Data.swift`（读缓存命中就不发请求）。
    @Published public var homeCacheLifetime: CacheLifetime {
        didSet {
            defaults.set(homeCacheLifetime.rawValue, forKey: StorageKey.homeCacheLifetime)
        }
    }

    // MARK: - 播放页与播放器（设置 → 播放）

    /// 播放页显示视图（精简视图 / Emby 视图）：详情页换排布，数据与交互都不变。
    @Published public var playbackPageLayout: PlaybackPageLayout {
        didSet {
            defaults.set(playbackPageLayout.rawValue, forKey: StorageKey.playbackPageLayout)
        }
    }

    /// 自动播放：首次进入详情页是否自动选中第一集开始播放（参考图副标题的原文语义）。
    ///
    /// 生效点在 `VodDetailView`：详情加载完成后按它决定是否自动进入第一集；
    /// 有「上次看到」的进度时以续播为准，不会把用户从上次位置拽回第一集。
    @Published public var autoPlayFirstEpisode: Bool {
        didSet {
            defaults.set(autoPlayFirstEpisode, forKey: StorageKey.autoPlayFirstEpisode)
        }
    }

    // MARK: - 弹幕 API（设置 → 播放 → 弹幕 API）

    /// 弹幕 API 配置：启用开关 + 四个地址槽位。
    ///
    /// 参考图里它的副标题写明「开启后将禁用视频源的弹幕功能」。
    /// 取用链见 `AppModel+Danmaku.swift`（M08a–M08c），调度见 `DanmakuPlan`（M08d），
    /// 上屏见 `DanmakuOverlay`（M08h，屏上效果待真机确认）。
    @Published public var danmakuAPI: DanmakuAPIConfig {
        didSet {
            defaults.set(danmakuAPI.persistenceValue, forKey: StorageKey.danmakuAPI)
            // 关掉开关就**立刻清屏**（M08d 遗留 2）：否则屏幕上还挂着已经载入的弹幕，用户会以为
            // 「这个开关没生效」。这里只管清 —— 重新打开不自动重载，下次进播放页或换集时自然就有。
            if !danmakuAPI.isEnabled {
                clearDanmaku()
            }
        }
    }

    // MARK: - 弹幕显示（设置 → 播放 → 弹幕显示）

    /// 弹幕显示设置：字号 / 透明度 / 速度 / 显示区域（M08i）。
    ///
    /// 与弹幕 API 分成两个类型、两把键：前者是「弹幕从哪儿取」，后者是「取到的弹幕怎么显示」，
    /// 用户改其一不该动到另一个。
    @Published public var danmakuDisplay: DanmakuDisplayConfig {
        didSet {
            defaults.set(danmakuDisplay.persistenceValue, forKey: StorageKey.danmakuDisplay)
        }
    }

    // MARK: - 字幕显示（设置 → 播放 → 字幕显示）

    /// 字幕显示设置：显示开关 / 字号 / 位置 / 背景（M09g）。
    ///
    /// 与弹幕显示同一套结构、两把键：字幕与弹幕的显示参数完全独立，
    /// 改一个不该动到另一个。
    @Published public var subtitleDisplay: SubtitleDisplayConfig {
        didSet {
            defaults.set(subtitleDisplay.persistenceValue, forKey: StorageKey.subtitleDisplay)
        }
    }

    // MARK: - 搜索历史（搜索页）

    /// 搜索历史：最近的在前，最多 `SearchHistory.limit` 条。
    ///
    /// 与其它设置一样「用户动作即落盘」（UserDefaults），重启后仍在。
    /// 规则（去重置顶 / 封顶 / 坏存档当空）在 `SearchHistory` 里，单测覆盖。
    @Published public var searchHistory: [String] {
        didSet {
            defaults.set(SearchHistory.encode(searchHistory), forKey: StorageKey.searchHistory)
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
            defaults.set(isEngineLogEnabled, forKey: StorageKey.engineLogEnabled)
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
            defaults.set(isLocalProxyEnabled, forKey: StorageKey.localProxyEnabled)
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
    /// 在 AppModel 里留一份而不是每次去问 actor：``playbackResource(_:)`` 是**同步**判定，
    /// 而 `LocalHTTPServer.port` 是 actor 属性，读它必须 await。
    ///
    /// setter 理由同 ``localProxyNotice``：启停逻辑在 `AppModel+LocalProxy.swift`。
    @Published public internal(set) var localProxyPort: UInt16?

    /// 本地偏好的存储（初始化时注入）：**读写都走它**，不再写死 `UserDefaults.standard`。
    ///
    /// 为什么统一走它：注入的 `defaults` 若只对读取生效、写入仍写 `UserDefaults.standard`，
    /// 那「隔离的测试存档」就是假的 —— 测试写出去的东西落到真存档里，而它自己又回读不到。
    /// 测试夹具（`AppModelFixture`）靠这一条才能真正验「写进去 → 新建一个模型读出来」。
    let defaults: UserDefaults

    /// 本地代理服务实例；由 ``ensureLocalServer()`` 创建并启动（见 `AppModel+LocalProxy.swift`）。
    var localServer: LocalHTTPServer?
    /// 广告清理规则（M06d）：接口配置里的 `hlsRules` 编译后放这里，
    /// 本机服务的 `/m3u8` 每个请求读一次（见 `AppModel+LocalProxy.swift`）。
    let adRuleStore = HLSAdRuleStore()

    // MARK: - js2p 宿主（JS 源）

    /// 宿主状态：界面据此显示「不可用 / 启动中 / 运行中 / 失败」，而不是一句笼统的占位文案。
    @Published public internal(set) var hostStatus: JS2PHostStatus = .idle

    /// 宿主提供的站点。
    ///
    /// JS 源时这是站点的**唯一**来源：`LoadedSource.config` 是空配置（站点清单要由 Node 执行后给出）。
    @Published public internal(set) var hostSites: [Site] = []

    /// 宿主会话（非 JS 源时为空）。
    /// 宿主服务实例（`internal`：`AppModel+Host.swift` 那簇宿主方法要读写它）。
    var js2pHost: JS2PHostService?

    /// js2p 站点的一次性 `POST /init` 记忆。
    ///
    /// **必须由 AppModel 持有**：`makeSiteClient()` 每次都会新建一个 `SiteClient`，
    /// 若让每个 `SiteClient` 自带一份记忆，就变成「每次动作都 init」
    /// （参考实现 `CatSpider.java` 是每个 spider 实例只 init 一次）。
    private let spiderInitializer = CatSpiderInitializer()

    // MARK: - 直播（M07c-2）

    // 直播清单的加载状态：`LiveState` 见 `AppModel+States.swift`（与 `LoadState` 一起搬出去的理由同它）。

    /// 当前选中的直播源名（落 `UserDefaults`；空表示用配置里的第一个源）。
    ///
    /// 一个接口里通常有好几个直播源（`SourceConfig.lives`），上游也是「先选源再看分组」，
    /// 所以选择要持久化，别每次进页面都跳回第一个。
    @Published public var selectedLiveKey: String {
        didSet {
            defaults.set(selectedLiveKey, forKey: StorageKey.liveSource)
        }
    }

    /// 当前选中的分组名（落 `UserDefaults`；空表示用清单里的第一个分组）。
    @Published public var selectedLiveGroup: String {
        didSet {
            defaults.set(selectedLiveGroup, forKey: StorageKey.liveGroup)
            // 换分组 = 换一批「可见频道」：预取封顶重新开始。
            // 已经拉过的频道靠「今天的节目单已经有了」跳过，不会重复请求。
            liveEPGPrefetchCount = 0
        }
    }

    /// 源级**文件**节目单（`epg` 里的 `.xml` / `.gz`）：一份覆盖多频道。
    ///
    /// 上游 `LiveActivity` 拿到清单后调 `LiveApi.parseXml(live)`（`EpgParser.start` 逐个文件），
    /// 这在本项目里此前**没有接线** —— 于是配了 `epg: "…/epg.xml"` 的源永远全屏「暂无节目」。
    /// 与 ``liveGuides`` 的分工：接口形态（x-tvg）按频道存，文件形态按整份存。
    @Published public internal(set) var liveFileGuide: EPGGuide?

    /// 直播页「可见即预取」（x-tvg 接口形态）的运行时状态。界面不直接读它，读的是
    /// ``liveGuides`` 与 ``liveEPGNotice``；因此这几个都不 `@Published`。
    ///
    /// 为什么需要刹车：接口形态**逐频道**拉，列表首屏不预取就全是「暂无节目」，而预取量随滚动增长。
    /// 判定规则在 `LiveEPGPrefetch`（纯函数，已单测）。
    var liveEPGPending: Set<String> = []
    var liveEPGFailed: Set<String> = []
    var liveEPGQueue: [LiveChannel] = []
    var liveEPGPrefetchCount = 0
    var liveEPGDraining = false

    /// 直播清单状态（`loaded` 里那份 `LiveSource` 带分组与频道）。
    ///
    /// setter 是 `internal(set)`：写入点在 `AppModel+Live.swift`（跨文件赋值，理由同 ``localProxyNotice``）。
    @Published public internal(set) var liveState: LiveState = .idle

    /// 节目单缓存：**频道 `epgID` → 已拿到的节目单**。
    ///
    /// 上游把 `Epg` 挂在频道对象上（`Channel.dataList`）；这里按 `epgID` 收在模型里 ——
    /// `LiveEPGRepository.load(channel:source:existing:)` 用这份缓存跳过「已有那天」的请求
    /// （M07c 的接口语义），界面换频道时也不必重复拉。
    @Published public internal(set) var liveGuides: [String: EPGGuide] = [:]

    /// 节目单拿不到时的原因（**不弹错**：界面上那一行显示「暂无节目」就行，
    /// 但原因要留痕，免得「为什么没有节目单」永远查不出来）。
    @Published public internal(set) var liveEPGNotice: String = ""

    /// 直播「上次观看」：**源名 → `分组名@@@频道名@@@线路下标`**（上游 `Live.keep` 的字符串形态）。
    ///
    /// 上游把这一行写在源对象自己的 `keep` 字段里、随配置落库；本项目不持有可写的配置副本
    /// （配置是只读解码出来的），所以按源名存进 `UserDefaults` —— 写法与 ``selectedLiveKey`` 一致。
    /// setter 是 `internal(set)`：唯一写回点是 `AppModel+Live.swift` 的 `rememberLiveChannel`。
    @Published public internal(set) var liveKeeps: [String: String] {
        didSet {
            defaults.set(LiveKeepBook.encode(liveKeeps), forKey: StorageKey.liveKeep)
        }
    }

    /// 直播**收藏频道**：**源名 → 收藏列表**（上游 `Keep` 表里 `type` 为直播的那些）。
    ///
    /// 与 ``liveKeeps``（上次观看位置）是两件事：这个是「收藏夹」，那个是「上次看到哪儿」；
    /// 上游也把两者分开存（`Keep` 表 vs. `Live.keep` 字段）。按源名分桶的理由同 ``liveKeeps``。
    @Published public internal(set) var liveFavorites: [String: [LiveFavorite]] {
        didSet {
            defaults.set(LiveFavoriteBook.encode(liveFavorites), forKey: StorageKey.liveFavorites)
        }
    }

    /// 直播 EPG 地址的**本地覆盖与历史**（上游 `LiveEpgSetting`：`live_epg_url` + 20 条历史）。
    ///
    /// 写一次就重算当前清单的频道地址（``AppModel/applyLiveEPGOverride``，只算不发请求）；
    /// 让节目单缓存作废并重拉文件形态的是 `updateLiveEPGSetting(_:)`（在 `AppModel+Live.swift`）。
    @Published public internal(set) var liveEPGSetting: LiveEPGSetting {
        didSet {
            defaults.set(liveEPGSetting.persistenceValue, forKey: StorageKey.liveEPGSetting)
            applyLiveEPGOverride()
        }
    }

    /// 上一次**解析结果**（还没套用本地 EPG 覆盖）。
    ///
    /// ``liveState`` 里那份是套用覆盖之后的；覆盖变了（含清空）由这份原始清单重算 ——
    /// 否则清掉覆盖时没法把频道地址还回去，也不必为此再拉一次清单。
    var rawLiveSource: LiveSource?

    /// 广告清理规则的**本地开关**：**状态键 → 开 / 关**（键由 ``HLSAdRuleState/key(origin:sourceID:ruleID:)`` 生成）。
    ///
    /// 改了要立刻重算规则（``AppModel/refreshAdRules()``）—— `/m3u8` 每个请求现读，所以不用重启本机服务。
    @Published public internal(set) var hlsAdRuleOverrides: [String: Bool] {
        didSet {
            defaults.set(HLSAdRuleBook.encode(hlsAdRuleOverrides), forKey: StorageKey.hlsAdRuleOverrides)
            refreshAdRules()
        }
    }

    /// 站点分组规则的**本地设置**：**接口摘要 → {关掉的规则 id, 用户自建规则}**（上游 `GroupRuleStore`）。
    ///
    /// 桶键同 ``siteNames``（接口地址摘要）：这是要落盘的东西，不存明文地址。
    @Published var siteGroupRuleSettings: [String: SiteGroupRuleSettings] {
        didSet {
            defaults.set(
                SiteGroupRuleBook.encode(siteGroupRuleSettings),
                forKey: StorageKey.siteGroupRules
            )
        }
    }

    /// 站点**自定义名**：**接口摘要 → {站点 key: 自定义名}**（上游 `SiteNameStore`，键 `site_names`）。
    ///
    /// 桶键是接口地址的摘要（`ConfigIdentity.key(for:)`）：地址可能带 token，落盘的东西不存明文。
    @Published public internal(set) var siteNames: [String: [String: String]] {
        didSet {
            defaults.set(SiteNameBook.encode(siteNames), forKey: StorageKey.siteNames)
        }
    }

    /// 发现页**上次选中的站点** key：跨 Tab 切换与冷启动保住选择；站点不在了由发现页那边回落。
    @Published public internal(set) var discoverSiteKey: String {
        didSet {
            defaults.set(discoverSiteKey, forKey: StorageKey.discoverSiteKey)
        }
    }

    /// 搜索页**上次选中的站点** key：与发现页**各自独立**（两页可以对着不同站点；还原规则共用 `SiteSelection`）。
    @Published public internal(set) var searchSiteKey: String {
        didSet {
            defaults.set(searchSiteKey, forKey: StorageKey.searchSiteKey)
        }
    }

    /// 聚合搜索里被用户**关掉**的站点 key（搜索页右上角「筛选站源」面板）。
    ///
    /// 两个入口共用这一份：搜索页与详情页 🔍 的海报墙都按它决定搜哪些站点。
    /// 存成数组（`Set` 不能直接进 `UserDefaults`），读回来再变回集合。
    @Published public internal(set) var searchExcludedSiteKeys: Set<String> {
        didSet {
            defaults.set(searchExcludedSiteKeys.sorted(), forKey: StorageKey.searchExcludedSites)
        }
    }

    /// 站点面板**分组条**的顺序：**接口地址 → 分组名数组**（上游 `SiteGroupOrderStore`，键 `site_group_order_<cid>`）。
    ///
    /// 按接口分桶的理由同直播那些书：换接口时分组名整套换掉，混在一起会互相污染。
    /// 排序规则不在这一层（在 `CatVodCore.SiteGroupOrder`），这里只管「算出来、存下来」。
    @Published public internal(set) var siteGroupOrders: [String: [String]] {
        didSet {
            defaults.set(SiteGroupOrderBook.encode(siteGroupOrders), forKey: StorageKey.siteGroupOrder)
        }
    }

    /// 已解锁的**加密分组**（键是 ``LiveGroupAccess/key(_:)``）。
    ///
    /// **不落盘**：密码只在这次运行里有效（上游 `mHides` 也是进程内的），换源即清空
    /// （`loadLivePlaylist` 里换源那条路会清）。写进 `UserDefaults` 意味着把源的密码留在磁盘上，
    /// 不划算。
    @Published var unlockedLiveGroups: Set<String> = []

    /// 「组名里的 `_` 不当密码」的本地覆盖：**源名 → 覆盖值**（上游 `Live.pass`）。
    ///
    /// 不在表里 = 跟源自己的 `pass` 字段。`pass` 是**解析期**字段，所以覆盖要在解析前套用
    /// （见 `AppModel+Live` 的 `loadLivePlaylist`），改这个开关会重新拉一次清单。
    @Published public internal(set) var livePassOverrides: [String: Bool] {
        didSet {
            defaults.set(LivePassBook.encode(livePassOverrides), forKey: StorageKey.livePassOverrides)
        }
    }

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
    let sessionTransport: URLSessionTransport
    /// 详情缓存（进程内共享）。
    let detailCache = DetailCache()

    /// TMDB 元信息的**会话缓存**（键 = 片名；只活进程内，不落盘）：详情页顶部与选集卡片共用同一次刮削。
    ///
    /// 缓存的是**建好的** ``TMDBBundle``（含取图模式）—— 模式对不上就当未命中（见 `tmdbBundle(for:mode:)`）。
    var tmdbBundleCache: [String: TMDBBundle] = [:]
    /// 正在飞的刮削（键 = 模式 + 片名）：同屏多处同时要同一片时只发一轮请求。
    var tmdbBundleInflight: [String: Task<TMDBMetadataOutcome, Never>] = [:]
    /// 站点传输的缓存（接口换过才重建，见 ``AppModel/transportForConfiguration()``）。
    var cachedTransport: HTTPTransport?

    /// 下载任务的落地目录（离线下载；默认在 Application Support 下，见 ``AppModel/downloadDirectory``
    /// 的静态默认）。做成实例属性是为了**测试能注入临时目录** —— 与 `cacheDirectory` 同一个理由。
    let downloadDirectory: URL
    /// 测试注入的下载传输（`nil` = 用 ``AppModel/transportForConfiguration()``）。
    let downloadTransportOverride: HTTPTransport?

    /// 测试注入的 TMDB 传输（`nil` = 按需新建 `URLSessionTransport`）：给「缓存 / 合流」的测试用。
    let tmdbTransportOverride: HTTPTransport?

    /// 已载入的弹幕行（M08c）：渲染层要用的原始数据（搜索与下载在 `CatVodSource.DanmakuService`）。
    @Published public internal(set) var danmakuLines: [DanmakuLine] = []

    /// 播放页那一行弹幕状态（`.idle` = 不显示）。
    @Published public internal(set) var danmakuStatus: DanmakuStatus = .idle

    // MARK: - 字幕（M09c）

    /// 已载入的字幕 cue（上屏见 `SubtitleOverlay`，M09f）。
    @Published public internal(set) var subtitleCues: [SubtitleCue] = []

    /// 播放页显示的「字幕：源 · N 条」状态行。
    @Published public internal(set) var subtitleStatus: SubtitleStatus = .idle

    // MARK: - 离线下载（M10e）

    /// 下载任务清单。
    ///
    /// 是**库的镜像**：任何写入都先落库再刷新（与收藏 / 播放进度同一套），
    /// 这样界面读到的永远是「库里的样子」，不会出现「界面上有、重启就没了」。
    @Published public internal(set) var downloadTasks: [DownloadTask] = []

    /// 队列驱动是否在跑（界面据此显示「正在下载」）。
    @Published public internal(set) var isDownloading = false

    /// 前台下载驱动的任务句柄（nil = 现在没有驱动在跑）。
    ///
    /// 与 `isDownloading` 分开：后者是「这一轮队列在跑」，前者是「有没有人负责把队列接着往下推」。
    var downloadDriverTask: Task<Void, Never>?

    /// 下载任务存储（GRDB；打开失败时降级为内存实现，与进度 / 收藏同一套）。
    public let downloadStore: DownloadTaskStore

    // MARK: - 播放信息（解析来源 / 描述）

    /// 这次播放是谁解的（上游 `Result.jxFrom`）。
    ///
    /// 为什么值得单独显示：解析来源是**排障信息** —— 「这集为什么播不出来」十次里有九次是
    /// 「哪个解析器解的、解成了什么」。显示出来，用户报问题时能一句话说清。
    @Published public internal(set) var parsedBy: String = ""

    /// 站点给的播放描述（上游 `Result.desc`）。
    @Published public internal(set) var playbackDesc: String = ""

    /// 跳过广告的统计（M06k）：本机服务的 `/m3u8` 在后台线程记账，这里持有同一个盒子。
    let adSkipRecorder = AdSkipRecorder()

    /// 播放页的「已跳过广告 N 段」提示（空 = 不显示）。
    ///
    /// 与 ``playbackNotice``（内核/解码这类**状态**说明）分开：那个是「为什么这样播」，
    /// 这个是「刚刚发生了什么」，前者常驻、后者跟着清理结果变。
    @Published public internal(set) var adSkipNotice: String = ""

    /// 构造；测试可注入缓存目录 / 存档 / 下载目录 / 传输层 / 本地库路径。
    /// - Parameter storageURL: 本地库路径；nil = 默认的 `Application Support/YPlayer/YPlayer.sqlite`。
    ///   测试把库放进夹具自己的临时目录 —— 否则并行用例共用一个库、互相写对方的数据。
    public init(
        cacheDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        downloadDirectory: URL? = nil,
        downloadTransport: HTTPTransport? = nil,
        storageURL: URL? = nil,
        tmdbTransport: HTTPTransport? = nil
    ) {
        let base = cacheDirectory ?? Self.defaultCacheDirectory()
        self.cacheDirectory = base
        self.downloadDirectory = downloadDirectory ?? Self.downloadDirectory
        downloadTransportOverride = downloadTransport
        tmdbTransportOverride = tmdbTransport
        self.defaults = defaults
        sessionTransport = URLSessionTransport()
        // 存储：优先 GRDB 落库（M08b）；打开失败退回内存实现并如实说明（不许静默）。
        // 这里只替换构造：两个 store 都是协议类型，详情页 / 追剧页 / 播放页一行都不用改。
        let storage = Self.openStorageDatabase(at: storageURL)
        storageDatabase = storage
        if let storage {
            progressStore = GRDBPlaybackProgressStore(database: storage)
            favoriteStore = GRDBFavoriteStore(database: storage)
            downloadStore = GRDBDownloadTaskStore(database: storage)
        } else {
            progressStore = InMemoryPlaybackProgressStore()
            favoriteStore = InMemoryFavoriteStore()
            downloadStore = InMemoryDownloadTaskStore()
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
        selectedLiveKey = defaults.string(forKey: StorageKey.liveSource) ?? ""
        selectedLiveGroup = defaults.string(forKey: StorageKey.liveGroup) ?? ""

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
        // 弹幕显示：默认值 = M08h 的行为（字号 0.8 / 不透明 / 中速 / 全屏）。
        danmakuDisplay = DanmakuDisplayConfig.decode(defaults.string(forKey: StorageKey.danmakuDisplay))
        // 字幕显示：默认值 = M09f 的行为（显示 / 基准字号 / 贴底 / 半透明底）。
        subtitleDisplay = SubtitleDisplayConfig.decode(defaults.string(forKey: StorageKey.subtitleDisplay))

        // 搜索历史：默认空（搜索页据此决定显示历史胶囊还是「还没有搜索记录」）。
        searchHistory = SearchHistory.decode(defaults.string(forKey: StorageKey.searchHistory) ?? "")

        // 直播「上次观看」：默认空（直播页据此决定要不要给「继续观看」入口）。
        liveKeeps = LiveKeepBook.decode(defaults.string(forKey: StorageKey.liveKeep) ?? "")

        // 直播收藏频道：默认空（分组条上据此决定要不要给「收藏」这一组）。
        liveFavorites = LiveFavoriteBook.decode(defaults.string(forKey: StorageKey.liveFavorites))

        // 直播 EPG 本地覆盖：默认空（用每个直播源自己配的 EPG）。
        liveEPGSetting = LiveEPGSetting.decode(defaults.string(forKey: StorageKey.liveEPGSetting))

        // 「组名里的 `_` 不当密码」的本地覆盖：默认空（跟每个直播源自己的 `pass` 字段）。
        livePassOverrides = LivePassBook.decode(defaults.string(forKey: StorageKey.livePassOverrides))

        // 站点面板分组条的顺序：默认空（= 每个接口都用「按站点顺序首次出现」的默认顺序）。
        siteGroupOrders = SiteGroupOrderBook.decode(defaults.string(forKey: StorageKey.siteGroupOrder))

        // 站点自定义名：默认空（= 全都用配置里的原始名）。
        siteNames = SiteNameBook.decode(defaults.string(forKey: StorageKey.siteNames))
        // 发现页上次选中的站点：默认空（= 回落站点清单里的第一个）。
        discoverSiteKey = defaults.string(forKey: StorageKey.discoverSiteKey) ?? ""
        // 搜索页上次选中的站点：与发现页各自独立（还原规则共用 `SiteSelection`）。
        searchSiteKey = defaults.string(forKey: StorageKey.searchSiteKey) ?? ""
        // 聚合搜索关掉的站点：默认空（= 只要能搜的站点都参与）。
        searchExcludedSiteKeys = Set(defaults.stringArray(forKey: StorageKey.searchExcludedSites) ?? [])

        // 站点分组规则的本地设置：默认空（= 四条内置全开、没有自建规则）。
        siteGroupRuleSettings = SiteGroupRuleBook.decode(defaults.string(forKey: StorageKey.siteGroupRules))

        // 广告清理规则的本地开关：默认空（= 按每条规则自己的默认值）。
        hlsAdRuleOverrides = HLSAdRuleBook.decode(defaults.string(forKey: StorageKey.hlsAdRuleOverrides))

        // 引擎日志：默认关（与参考图的开关初始状态一致）。
        isEngineLogEnabled = defaults.object(forKey: StorageKey.engineLogEnabled) as? Bool ?? false
        refreshPlaybackNotice()

        // 跳过广告的提示（M06k）：统计产生在本机服务的线程池里，这里把它带回主线程。
        // 放在 init 末尾是因为闭包捕获 self，必须等所有存储属性就位。
        adSkipRecorder.setListener { [weak self] stats in
            Task { @MainActor [weak self] in
                self?.applyAdSkip(stats)
            }
        }
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
    func bumpSiteCatalogRevision() {
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
            // 广告清理规则随配置一起换新（M06d）：本机服务的 `/m3u8` 每个请求读一次，不重启服务。
            refreshAdRules()
            // 缓存里的传输也作废：header / 广告拦截 / 代理都来自旧配置（M06j）。
            cachedTransport = nil
            // 跳过广告的累计统计也归零：换了接口就是新的一轮（M06k）。
            resetAdSkip()
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
    /// 站点传输（按当前接口配置构造）。
    ///
    /// **按接口缓存**：代理会话池、cookie、连接复用都挂在传输内部的 `URLSession` 上 ——
    /// 每次动作都新建一个传输，等于每次动作都重建连接与 cookie（好多站点靠同一条连接上的 cookie 认人）。
    /// 缓存键就是「配置是否换过」：``load(forceRefresh:)`` 会把它清掉，所以换接口必然重建。
    public func transportForConfiguration() -> HTTPTransport {
        if let cachedTransport {
            return cachedTransport
        }
        guard let config = state.loadedSource?.config else {
            return sessionTransport
        }
        let transport = URLSessionTransport(configuration: Self.transportConfiguration(for: config))
        cachedTransport = transport
        return transport
    }

    /// 从接口配置造传输层配置：header / 广告拦截 / **代理选择器**。
    ///
    /// 代理是 M06j 接上的：Core 早就把「按 host 选哪条代理」算好了（``ProxyRuleResolver``），
    /// 这里只是把它包成传输层要的闭包 —— 代理端点列表里**第一条**生效。
    /// 上游是「按顺序失败切换」（OkHttp 的 proxy 列表语义），那一层**没做**（见 M06j 记录的遗留）。
    static func transportConfiguration(for config: SourceConfig) -> URLSessionTransport.Configuration {
        var configuration = URLSessionTransport.Configuration(config: config)
        let resolver = ProxyRuleResolver(rules: config.proxy)
        guard !resolver.isEmpty else {
            return configuration
        }
        configuration.proxyResolver = { host in
            resolver.selection(forHost: host).endpoints.first
        }
        return configuration
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

    // 宿主维护（`refreshHost` / `restartHost` / `stopHost` / `hostLogPath` / `hostDiagnostics` /
    // `applyLogPreferenceToHost`）已搬到 `AppModel+Host.swift`：那一簇的依赖只有 `js2pHost` /
    // `sessionTransport` / `detailCache` 三个存储属性，是类体里最好搬的一块。

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

    // MARK: - 工具

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
