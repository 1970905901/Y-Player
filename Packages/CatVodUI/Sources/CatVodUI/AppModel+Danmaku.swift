import CatVodCore
import CatVodSource
import Foundation

// 弹幕的界面接线（M08c）：设置页里填的地址槽**真的被用起来**，播放页显示一行状态。
//
// 这一层只做「把服务接上」：搜索 → 候选 → 下载 → 解析都在 `CatVodSource.DanmakuService` 里、
// 且有单测（M08a/M08b）。这里负责挑地址、管状态、把错误变成一句人话。
//
// M03P25 起还管「手动选一条 / 换关键词重搜」（对齐上游 `DanmakuDialog` / `DanmakuSearchDialog`）：
// 候选与选中都住在这里，播放页只拿一个 `playbackDanmakuSwitcher`。
//
// 上屏见 `DanmakuOverlay`（M08h）：拿 `danmakuLines` 排一次计划，再按播放时间逐帧画到视频上。

public extension AppModel {
    /// 载入一集的弹幕。
    ///
    /// 几条刻意的取舍：
    /// - **不抛错**：弹幕是锦上添花，失败只该影响播放页那一行提示，不该把播放流程带崩；
    /// - 开关关着、或四个槽位都空 → 什么都不做、也不提示（那是用户的设置，不是错误）；
    /// - 用 `search` + `lines(from:)` 而不是 `load`：这样能知道**是哪条源**给的弹幕，写进状态行；
    /// - 传输复用 ``AppModel/transportForConfiguration()``：接口 header、代理、广告拦截都与站点一致
    ///   （测试可注入，见下面的 `danmakuTransport`）；
    /// - **换集就清掉手动选择**（M03P25）：上游的选择活在本次播放的 `PlaySpec` 里，只有同一集
    ///   重新载入（换线路）才保留 —— 不同集对上的弹幕文件往往不是同一条，跟着走反而会串集。
    ///
    /// - Parameter embedded: 站点结果自带的弹幕源（``SpiderResult/danmaku``）。它**优先于** API 搜索
    ///   —— 上游 `VodPlaybackMedia.searchDanmaku` 里的 `DanmakuSetting.isSpiderFirst()` 就是这个意思
    ///   （M09e）。站点自己给的源通常跟它的片源/集名对得上，而 API 搜索是按片名猜的。
    func loadDanmaku(_ request: DanmakuRequest, embedded: [DanmakuSource] = []) async {
        guard danmakuAPI.isEnabled, !request.isEmpty else {
            clearDanmaku()
            return
        }
        danmakuStatus = .loading
        danmakuLines = []
        let service = DanmakuService(transport: danmakuTransport())

        var searched: [DanmakuSource] = []
        if let api = danmakuAPI.filledAddresses.first {
            searched = await (try? service.search(api: api, name: request.name, episode: request.episode)) ?? []
        }
        danmakuCandidates = PlaybackDanmakuSwitcher.candidates(embedded: embedded, searched: searched)
        if danmakuRequest != request {
            // 换集了：上一次手动选的那条不再算数（理由见上面的文档）。
            danmakuPick = nil
        }
        danmakuRequest = request
        await applyDanmaku(danmakuPick ?? DanmakuSourceSelection.firstUsable(danmakuCandidates))
    }

    /// 手动选一条候选（`nil` = 回到「自动」）：当场换过来（M03P25，对齐上游 `DanmakuDialog` 的点击）。
    ///
    /// 选中**不进存档**（上游同款）：接口给的弹幕地址可能带时效，存下来的地址下次多半已经失效，
    /// 那会变成一句莫名其妙的「加载失败」；要长期记住得连「按片 / 按集」一起设计，留给以后。
    func selectDanmaku(_ source: DanmakuSource?) async {
        danmakuPick = source
        await applyDanmaku(source ?? DanmakuSourceSelection.firstUsable(danmakuCandidates))
    }

    /// 换关键词重搜（上游 `DanmakuSearchDialog`）：只换候选列表，**不动**当前在播的那份弹幕。
    ///
    /// 新搜到的接在现有候选后面（站点自带的那几条本来就是这一集的候选，留在前面）。
    ///
    /// - Returns: `nil` = 搜到了（候选已换）；有值 = 没搜成的原因（面板那一行如实显示）。
    func searchDanmaku(name: String, episode: String) async -> String? {
        guard danmakuAPI.isEnabled else {
            return "弹幕 API 没开：设置 → 播放 → 弹幕 API"
        }
        let request = DanmakuRequest(name: name, episode: episode)
        guard !request.isEmpty else {
            return "片名和集名不能都是空的"
        }
        guard let api = danmakuAPI.filledAddresses.first else {
            return "还没填弹幕 API 地址（设置 → 播放 → 弹幕 API）"
        }
        do {
            let searched = try await DanmakuService(transport: danmakuTransport())
                .search(api: api, name: request.name, episode: request.episode)
            danmakuCandidates = PlaybackDanmakuSwitcher.candidates(embedded: danmakuCandidates, searched: searched)
            return nil
        } catch {
            return userFacingMessage(error)
        }
    }

    /// 播放页「选择弹幕」要的那一包（M03P25）：候选 / 当前选中 / 状态行 + 两个动作。
    ///
    /// 宿主只传这一个值（与 `playbackInfoRows` 同一套手法），播放页不认识 `AppModel`。
    var playbackDanmakuSwitcher: PlaybackDanmakuSwitcher {
        PlaybackDanmakuSwitcher(
            candidates: danmakuCandidates,
            selected: danmakuPick,
            status: danmakuStatus.text,
            select: { source in await self.selectDanmaku(source) },
            search: { name, episode in await self.searchDanmaku(name: name, episode: episode) }
        )
    }

    /// 清掉弹幕状态与已载入的行（换集 / 退出播放时用）。
    func clearDanmaku() {
        danmakuLines = []
        danmakuStatus = .idle
        danmakuCandidates = []
        danmakuPick = nil
        danmakuRequest = nil
    }

    /// 弹幕取用链的传输：**测试注入优先**，否则与站点请求同一套（接口 header / 代理 / 广告拦截口径一致）。
    /// 与 ``AppModel/downloadTransport()`` 同一套做法 —— 没有它，「搜索 → 候选 → 换一条」这段接线
    /// 在单测里只能干看着（M03P25 补的）。
    ///
    /// 可见性是「模块内」而不是 `private`：注入口那个 `init` 参数与它同名（都是 `danmakuTransport`），
    /// 而 `init` 体里的参数引用会被 `check_visibility.py` 当成「跨文件引 private 成员」误报
    /// （`downloadTransport()` 之所以没这问题，也是因为它不是 private）。
    func danmakuTransport() -> HTTPTransport {
        danmakuTransportOverride ?? transportForConfiguration()
    }

    /// 把选中的那条来源换成屏上的弹幕行（M03P25：从 `loadDanmaku` 里拆出来，换条 / 重搜都要用）。
    ///
    /// `nil` = 一条可用的都没有：如实给状态（没搜到 / 连地址都没填），别留上一集的旧行。
    private func applyDanmaku(_ source: DanmakuSource?) async {
        guard let source else {
            danmakuLines = []
            danmakuStatus = danmakuCandidates.isEmpty ? .idle : .empty
            return
        }
        danmakuStatus = .loading
        danmakuLines = []
        do {
            let lines = try await DanmakuService(transport: danmakuTransport()).lines(from: source)
            danmakuLines = lines
            // 文件是空的与「没搜到候选」分开说：这条的下一步是「换一条」，不是去改 API 地址。
            danmakuStatus = lines.isEmpty
                ? .emptySource(source.displayName)
                : .loaded(source: source.displayName, count: lines.count)
        } catch {
            danmakuStatus = .failed(userFacingMessage(error))
        }
    }
}
