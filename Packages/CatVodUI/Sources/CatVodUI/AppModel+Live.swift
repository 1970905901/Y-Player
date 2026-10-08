import CatVodCore
import CatVodNet
import CatVodSource
import Foundation

// 直播页（M07c-2）的状态与 IO。
//
// 与点播同一条链路：配置的 `lives` → `LiveRepository`（取清单 → 解析成带分组频道的源）
// → `LiveEPGRepository`（节目单：文件 / 接口两种形态，M07b 与 M07c 已落地）。
// 这里只做三件事：选源与选分组的持久化、清单与节目单的按需加载、把错误翻成一句人话。

@MainActor
public extension AppModel {
    /// 配置里的直播源（`SourceConfig.lives`）。
    var liveSources: [LiveSource] {
        state.loadedSource?.config.lives ?? []
    }

    /// 当前选中的直播源：`selectedLiveKey` 命中就用它，否则回落配置里的第一个。
    var selectedLiveSource: LiveSource? {
        let sources = liveSources
        guard !sources.isEmpty else {
            return nil
        }
        return sources.first { $0.name == selectedLiveKey } ?? sources.first
    }

    /// 已解析的清单（含分组与频道）；还没加载过时为 `nil`。
    var liveSource: LiveSource? {
        liveState.loadedSource
    }

    /// 当前源「组名里的 `_` 不当密码」的**有效值**：本地覆盖优先，否则跟源自己的 `pass`（上游同字段）。
    var liveGroupPassEnabled: Bool {
        guard let source = selectedLiveSource else {
            return false
        }
        return livePassOverrides[source.name] ?? source.pass
    }

    /// 改这个开关：落盘 → **重新解析**清单（`pass` 是解析期字段）+ 重拉文件形态节目单。
    ///
    /// 上游 `Live.pass(boolean)` 就是「清空 groups 后重新解析」（`getGroups().clear()`），
    /// 这里做的是同一件事；只是本项目不缓存清单文本，所以要重新请求一次（一次请求，能接受）。
    ///
    /// 为什么要给两个方向都能拨：有些源自己写了 `pass: true`，而用户的实际分组名里没有密码 ——
    /// 那就得能关掉；反过来（源里没写、组名里却有 `_`）也得能打开，否则那几组会被当成加密分组藏起来。
    func setLiveGroupPass(_ enabled: Bool) async {
        guard let name = selectedLiveSource?.name, !name.isEmpty else {
            return
        }
        guard liveGroupPassEnabled != enabled else {
            return
        }
        livePassOverrides = LivePassBook.setting(enabled, for: name, in: livePassOverrides)
        await loadLivePlaylist(force: true)
        await loadLiveFileGuide(force: true)
    }

    /// 界面上要显示的分组：**未解锁的加密分组不出现**（上游把它们收在 `mHides` 里）。
    var liveVisibleGroups: [LiveGroup] {
        guard let source = liveSource else {
            return []
        }
        return LiveGroupAccess.visible(source.groups, unlocked: unlockedLiveGroups)
    }

    /// 还锁着的加密分组（分组条据此决定要不要给「解锁」入口、以及入口上写几个）。
    var liveLockedGroups: [LiveGroup] {
        guard let source = liveSource else {
            return []
        }
        return LiveGroupAccess.locked(source.groups, unlocked: unlockedLiveGroups)
    }

    /// 用密码解锁加密分组；解锁成功就把**第一组**选中（上游 `unlock` 里 `if (first) onItemClick(item)`）。
    ///
    /// 返回解锁了几组：`0` 表示密码不对（界面据此给反馈，而不是默默什么也不做）。
    @discardableResult
    func unlockLiveGroups(with pass: String) -> Int {
        guard let source = liveSource else {
            return 0
        }
        let unlocked = LiveGroupAccess.unlocking(source.groups, with: pass)
        guard !unlocked.isEmpty else {
            return 0
        }
        for group in unlocked {
            unlockedLiveGroups.insert(LiveGroupAccess.key(group))
        }
        if let first = unlocked.first {
            selectedLiveGroup = first.name
        }
        return unlocked.count
    }

    /// 当前选中的分组：按名字取，找不到就用清单里第一个**可见**的分组。
    ///
    /// 「收藏」是个**运行时分组**（不在清单里，由 ``liveFavoriteGroup`` 现算），所以单独接一下：
    /// `selectedLiveGroup` 存的是它的名字。收藏清空后（或收藏的频道都不在清单里）自动回落第一个真分组。
    /// **锁着的加密分组不会被选中**：它们根本不在 ``liveVisibleGroups`` 里（上游同此）。
    var selectedLiveGroupObject: LiveGroup? {
        let visible = liveVisibleGroups
        guard !visible.isEmpty else {
            return nil
        }
        if selectedLiveGroup == LiveGroup.keepName, let favorites = liveFavoriteGroup {
            return favorites
        }
        return visible.first { $0.name == selectedLiveGroup } ?? visible.first
    }

    /// 设置页里的直播源列表：顺序即配置顺序；勾的是**当前生效**的那个
    /// （`selectedLiveKey` 为空时是配置里的第一个，不是「没勾」）。
    var liveSourceRows: [LiveSourceRow] {
        LiveSourceList.rows(liveSources, selected: selectedLiveSource?.name ?? "", loaded: liveState.loadedSource)
    }

    /// 换一个直播源（直播设置里选源）：落盘后强制重载清单与文件形态节目单。
    ///
    /// `loadLivePlaylist(force: true)` 本身会清掉节目单缓存与预取状态（换源后同一个 `epgID` 可能
    /// 指向另一个频道），这里不必再各清一遍。
    func selectLiveSource(_ name: String) async {
        guard name != selectedLiveSource?.name, liveSources.contains(where: { $0.name == name }) else {
            return
        }
        selectedLiveKey = name
        await loadLivePlaylist(force: true)
        await loadLiveFileGuide(force: true)
    }

    /// 当前源的收藏列表（没有就是空数组）。
    var liveFavoriteList: [LiveFavorite] {
        guard let sourceName = selectedLiveSource?.name else {
            return []
        }
        return liveFavorites[sourceName] ?? []
    }

    /// 「收藏」分组（上游 `LiveConfig.applyKeepsToGroups` 的第 0 组）；没有命中任何频道时为 `nil`。
    var liveFavoriteGroup: LiveGroup? {
        guard let source = liveSource else {
            return nil
        }
        return LiveFavorites.group(in: source, favorites: liveFavoriteList)
    }

    /// 这个频道收藏了没有（界面据此显示星标、切换菜单标题）。
    func isLiveFavorite(_ channel: LiveChannel) -> Bool {
        LiveFavorites.contains(channel.name, in: liveFavoriteList)
    }

    /// 收藏 / 取消收藏（上游 `LiveActivity.onLongClick`）。
    ///
    /// 两条与上游一致的闸门：
    /// - **加密（隐藏）分组里的频道不给收藏**（上游 `if (mGroup.isHidden()) return false;`）；
    /// - 分组按**频道名回查**：从「收藏」分组里操作时，也要落回它真正所在的组。
    func toggleLiveFavorite(_ channel: LiveChannel) {
        guard let source = liveSource, let sourceName = selectedLiveSource?.name, !sourceName.isEmpty else {
            return
        }
        guard let target = LiveKeep.locate(channelNamed: channel.name, in: source), !target.group.isHidden else {
            return
        }
        let favorite = LiveFavorite(name: channel.name, logo: channel.logo, group: target.group.name)
        let updated = LiveFavorites.toggling(favorite, in: liveFavoriteList)
        liveFavorites = LiveFavoriteBook.recording(updated, for: sourceName, in: liveFavorites)
    }

    /// 某频道现在的节目单：接口形态按 `epgID` 存（``liveGuides``），文件形态一份覆盖多频道（``liveFileGuide``）。
    ///
    /// 两者按键取值的语义一样（`epgID` = XMLTV 的 channel id，M07a 的三级回落），
    /// 所以界面与行模型不必区分；接口形态更贴这个频道，优先。
    func liveGuide(for channel: LiveChannel) -> EPGGuide? {
        liveGuides[channel.epgID] ?? liveFileGuide
    }

    /// 当前源的上次观看：先看本地存档（``liveKeeps``），再回落源自己的 `keep` 字段。
    ///
    /// 上游把这一行写在源对象上、随配置一起带过来（`Live.getKeep()`），所以源的 `keep`
    /// 是「别人给的起始值」，本地存档是「这台机器上真实看过的那一次」，后者优先。
    var liveKeep: LiveKeep? {
        guard let source = selectedLiveSource else {
            return nil
        }
        if let raw = liveKeeps[source.name], let stored = LiveKeep(raw: raw) {
            return stored
        }
        return LiveKeep(raw: source.keep)
    }

    /// 上次观看落到当前清单上的结果（分组 / 频道 / 线路）。
    ///
    /// 清单还没加载、或记录里的频道已经不在清单里 → `nil`（界面就不给「继续观看」入口）。
    var liveResumeTarget: LiveKeepTarget? {
        guard let source = liveSource, let keep = liveKeep else {
            return nil
        }
        return keep.resolve(in: source)
    }

    /// 记一次「上次观看」（界面在打开频道 / 换线路时调用）。
    ///
    /// 写的是**上游那一行**：`分组名@@@频道名@@@线路下标`（`LiveKeep` 负责编码），键是当前源名。
    /// 两条闸门：
    /// - 分组**按频道名回查**（``LiveKeep/locate(channelNamed:in:line:)``）—— 从「收藏」分组点进去的
    ///   频道也要写它真正所在的组，源更新过搬了组也不会写错；
    /// - **加密（隐藏）分组里的频道不记**（上游 `LiveConfig.setKeep`：`!channel.getGroup().isHidden()`）。
    func rememberLiveChannel(_ channel: LiveChannel, lineIndex: Int) {
        guard let source = liveSource, let sourceName = selectedLiveSource?.name, !sourceName.isEmpty else {
            return
        }
        guard let target = LiveKeep.locate(channelNamed: channel.name, in: source, line: lineIndex),
              !target.group.isHidden
        else {
            return
        }
        let keep = LiveKeep(group: target.group.name, channel: target.channel.name, line: target.lineIndex)
        liveKeeps = LiveKeepBook.recording(keep, for: sourceName, in: liveKeeps)
    }

    /// 加载选中源的清单。
    ///
    /// 已经是这个源的已解析结果就直接返回（``LiveRepository/load(_:)`` 自己也短路），
    /// `force` 用于界面上的「重新加载」。
    func loadLivePlaylist(force: Bool = false) async {
        guard let source = selectedLiveSource else {
            liveState = .failed("当前接口里没有直播源（配置的 `lives` 为空）")
            return
        }
        if !force, let loaded = liveState.loadedSource, loaded.name == source.name, !loaded.groups.isEmpty {
            return
        }
        // 换源 / 强制重载时清掉节目单缓存：缓存按 `epgID` 存，换源后同一个 `epgID` 可能指向另一个频道。
        let previousName = liveState.loadedSource?.name
        liveState = .loading
        rawLiveSource = nil
        if force || previousName != source.name {
            resetLiveEPGState()
            // 换了源（或强制重载）：解锁状态一起作废 —— 密码是上一个源的，不该带到下一个源。
            unlockedLiveGroups.removeAll()
        }
        do {
            let repository = LiveRepository(transport: transportForConfiguration())
            // 「组名里的 `_` 不当密码」的本地覆盖要在**解析前**套上（`pass` 是解析期字段，
            // 它决定组名怎么拆、进而决定哪些组算加密分组）。
            let effective = source.applyingGroupPass(livePassOverrides[source.name])
            let loaded = try await repository.load(effective)
            // 解析结果按原样留底；``liveState`` 里放的是套用本地 EPG 覆盖**之后**的那份
            // （上游也是拿到清单就 `LiveEpgSetting.apply(live)`）。
            rawLiveSource = loaded
            let effective = effectiveLiveSource(from: loaded)
            liveState = .loaded(effective)
            restoreLiveGroup(in: effective)
        } catch {
            liveState = .failed(Self.liveMessage(error))
        }
    }

    /// 套用本地 EPG 覆盖后的源（纯变换，见 ``LiveEPGOverride``）。
    private func effectiveLiveSource(from raw: LiveSource) -> LiveSource {
        LiveEPGOverride(url: liveEPGSetting.url).applying(to: raw)
    }

    /// 覆盖变了：拿**原始**清单重算一次（不发请求）。清单还没加载过就什么都不做。
    ///
    /// 由 ``AppModel/liveEPGSetting`` 的 `didSet` 调用 —— 只负责让界面上的频道地址立刻变过来；
    /// 「让节目单缓存作废 + 重拉文件形态」是 ``updateLiveEPGSetting(_:)`` 的事。
    func applyLiveEPGOverride() {
        guard let raw = rawLiveSource else {
            return
        }
        liveState = .loaded(effectiveLiveSource(from: raw))
    }

    /// 换一个 EPG 覆盖地址（空串 = 清除覆盖），并把节目单状态整体作废后重拉文件形态。
    func updateLiveEPGSetting(_ value: String) async {
        await applyLiveEPGSetting(liveEPGSetting.using(value))
    }

    /// 从历史里删一条（删的是当前在用的那条就一并清掉覆盖），同样按需重算。
    func removeLiveEPGHistory(_ value: String) async {
        await applyLiveEPGSetting(liveEPGSetting.removing(value))
    }

    /// 清空历史：不动当前覆盖，也就不需要重拉任何东西。
    func clearLiveEPGHistory() {
        liveEPGSetting = liveEPGSetting.clearingHistory()
    }

    /// 落一个设置值；**地址真的换了**才作废节目单并重拉（删历史里无关的一条不必发请求）。
    private func applyLiveEPGSetting(_ updated: LiveEPGSetting) async {
        let urlChanged = updated.url != liveEPGSetting.url
        liveEPGSetting = updated
        guard urlChanged else {
            return
        }
        // 模板换了，旧的按频道结果不再对得上；文件形态立刻重拉一次，
        // 逐频道那些由列表的「可见即预取」自然重来（缓存已清空 → `shouldQueue` 会重新排队）。
        liveGuides.removeAll()
        liveEPGFailed.removeAll()
        liveEPGPending.removeAll()
        liveEPGQueue.removeAll()
        liveEPGPrefetchCount = 0
        liveFileGuide = nil
        liveEPGNotice = ""
        await loadLiveFileGuide(force: true)
    }

    /// 清空节目单相关的全部状态（换源 / 强制重载时用）：缓存、队列、失败名单、预取计数、提示。
    private func resetLiveEPGState() {
        liveGuides.removeAll()
        liveFileGuide = nil
        liveEPGPending.removeAll()
        liveEPGFailed.removeAll()
        liveEPGQueue.removeAll()
        liveEPGPrefetchCount = 0
        liveEPGNotice = ""
    }

    /// 清单到齐后把分组条切回「上次观看」那一组。
    ///
    /// 只切分组，**不自动开播**：进页面就出声是打扰（上游 `LiveActivity` 也是列表优先，
    /// 是否续播交给用户点）。频道本身的入口由 ``liveResumeTarget`` 摆在列表上方。
    private func restoreLiveGroup(in source: LiveSource) {
        guard let target = liveKeep?.resolve(in: source), selectedLiveGroup != target.group.name else {
            return
        }
        selectedLiveGroup = target.group.name
    }

    /// 拉**源级文件**节目单（`epg` 里的 `.xml` / `.gz`，上游 `LiveApi.parseXml`）：一份覆盖多频道。
    ///
    /// 时机对齐上游 `LiveActivity.onLiveParsed(live)` → `mViewModel.parseXml(live)`：清单到手就拉一次。
    /// 上游按「不是今天 / 超过 6 小时」判要不要重下（`EpgParser.refreshReason`），本项目不落盘，
    /// 只用「缺今天」那一半（``EPGGuide/coversToday(now:)``）—— 进程重启内存缓存就没了，6 小时那半不需要。
    ///
    /// 没配文件形态（源自己的 `epgXML` 为空、本地覆盖也不是整源 XML）时**直接返回**：
    /// 那是接口形态的活，由 ``requestLiveGuide(for:)`` 按可见频道逐频道拉。
    func loadLiveFileGuide(force: Bool = false) async {
        guard let source = liveState.loadedSource else {
            return
        }
        let override = LiveEPGOverride(url: liveEPGSetting.url)
        // 传**原始**清单算地址列表：套过覆盖的那份里 `epg` 已经含覆盖地址（去重也兜得住，原始的更清楚）。
        let entries = override.fileURLs(for: rawLiveSource ?? source)
        guard !entries.isEmpty else {
            return
        }
        if !force, let guide = liveFileGuide, guide.coversToday() {
            return
        }
        do {
            let repository = LiveEPGRepository(transport: transportForConfiguration())
            liveFileGuide = try await repository.load(source, fileURLs: entries)
            liveEPGNotice = ""
        } catch {
            // 一次进入只发这一次请求，所以这里不「静默」：拿不到就在列表上方说清楚原因。
            liveEPGNotice = Self.liveMessage(error)
        }
    }

    /// 列表里一个频道「露面了」：排队拉它的节目单（**串行 + 去重 + 失败不重试 + 封顶**）。
    ///
    /// 由 `LiveView` 频道行的 `.task` 调用 —— 只有真的被渲染出来的频道才会进来。
    /// 与 ``loadLiveGuide(for:quiet:)`` 的分工：这里负责「值不值得拉」的判定与排队，
    /// 真正发请求的还是同一个方法（`quiet = true`：一次失败不该把提示刷屏）。
    func requestLiveGuide(for channel: LiveChannel) {
        let shouldQueue = LiveEPGPrefetch.shouldQueue(channel, state: liveEPGPrefetchState(for: channel))
        guard shouldQueue else {
            return
        }
        liveEPGPending.insert(channel.epgID)
        liveEPGQueue.append(channel)
        drainLiveEPGQueueIfIdle()
    }

    /// 预取判定要用的当前状态（`LiveEPGPrefetch` 是纯函数，状态由这里喂）。
    private func liveEPGPrefetchState(for channel: LiveChannel) -> LiveEPGPrefetchState {
        LiveEPGPrefetchState(
            guide: liveGuide(for: channel),
            pending: liveEPGPending,
            failed: liveEPGFailed,
            prefetched: liveEPGPrefetchCount,
            budget: LiveEPGPrefetch.defaultBudget
        )
    }

    /// 串行抽干队列：一次只发一个请求（对源最客气，也不会把连接堆满）。
    private func drainLiveEPGQueueIfIdle() {
        guard !liveEPGDraining else {
            return
        }
        liveEPGDraining = true
        Task { [weak self] in
            guard let self else {
                return
            }
            while let next = popLiveEPGQueue() {
                await loadLiveGuide(for: next, quiet: true)
                // 出队即从「在飞」名单里摘掉：留着会让这个频道**再也排不进队**（跨天重拉就靠它）。
                liveEPGPending.remove(next.epgID)
            }
            liveEPGDraining = false
        }
    }

    /// 取队列里下一个该拉的频道（顺手记一次预取）；空队列或到顶返回 `nil`。
    private func popLiveEPGQueue() -> LiveChannel? {
        guard !liveEPGQueue.isEmpty else {
            return nil
        }
        guard liveEPGPrefetchCount < LiveEPGPrefetch.defaultBudget else {
            // 到顶：剩下的不拉了（点开某个频道时仍会即时拉），但把原因说清楚。
            for rest in liveEPGQueue {
                liveEPGPending.remove(rest.epgID)
            }
            liveEPGQueue.removeAll()
            liveEPGNotice = "本次进入已预取 \(LiveEPGPrefetch.defaultBudget) 个频道的节目单；其余频道点开时再拉。"
            return nil
        }
        liveEPGPrefetchCount += 1
        return liveEPGQueue.removeFirst()
    }

    /// 拉一个频道的节目单（**x-tvg 接口形态**：逐频道 × 昨天 / 今天 / 明天；文件形态走 ``loadLiveFileGuide(force:)``）。
    ///
    /// 三件事：
    /// - **今天已经有了就不请求**（``EPGGuide/coversToday(key:now:)``）：文件形态覆盖今天、或之前拉过；
    ///   这也是跨天重拉的入口 —— 昨天那份在今天不再「覆盖今天」，于是会重新拉；
    /// - 失败**不当错误处理**：界面上这一行显示「暂无节目」就行，原因留在 ``liveEPGNotice``
    ///   （上游 `fetchEpgDay` 也是吞掉异常，不让某个频道的节目单拖垮整页）；
    /// - `quiet` 供预取队列用：滚一遍长列表时，逐个频道的失败提示没有意义（只影响那一行）。
    func loadLiveGuide(for channel: LiveChannel, quiet: Bool = false) async {
        guard let source = liveState.loadedSource else {
            return
        }
        if let guide = liveGuide(for: channel), guide.coversToday(key: channel.epgID) {
            return
        }
        do {
            let repository = LiveEPGRepository(transport: transportForConfiguration())
            let guide = try await repository.load(
                channel: channel,
                source: source,
                existing: liveGuides[channel.epgID]
            )
            liveGuides[channel.epgID] = guide
            liveEPGFailed.remove(channel.epgID)
            liveEPGNotice = ""
        } catch {
            liveEPGFailed.insert(channel.epgID)
            if !quiet {
                liveEPGNotice = Self.liveMessage(error)
            }
        }
    }

    /// 错误 → 界面能读的一句话（``CatVodError`` 自带 `errorDescription`）。
    private static func liveMessage(_ error: Error) -> String {
        (error as? CatVodError)?.errorDescription ?? String(describing: error)
    }
}
