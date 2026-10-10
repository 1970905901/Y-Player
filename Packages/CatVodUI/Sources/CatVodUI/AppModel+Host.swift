import CatVodCore
import CatVodNet
import CatVodSource
import Foundation

// JS2P 宿主（内嵌 Node）的启停、日志与诊断 —— 从 `AppModel` 类体搬出来的第一簇（M06f 遗留第 3 条）。
//
// 为什么先搬它：依赖只有 `js2pHost` / `sessionTransport` / `detailCache` 三个存储属性，内聚度最高、
// 搬动风险最小（存储属性必须留在类体里，这几簇能进扩展的都进扩展，`type_body_length` 才有余量）。

public extension AppModel {
    /// 按加载结果维护宿主：JS 源启动/刷新，其它源停止。
    internal func refreshHost(for source: LoadedSource, forceRestart: Bool) async {
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

        // 换了 JS 源：宿主跑的还是上一个 bundle（内嵌 node 每进程只起得了一个实例），
        // 停掉再换一个 —— 否则站点清单永远来自上一个接口。
        if let existing = js2pHost, existing.runtimeConfiguration.scriptURL != scriptURL {
            await existing.stop()
            js2pHost = nil
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
            // bundle 刚被换过（本次加载真的重下了，`usedCache == false`）就必须重启宿主：
            // 运行中的 node 已经把旧代码执行过，站点清单在内存里 —— 只换磁盘上的文件它不会自己重读。
            // 这是「明明下载了新版本、界面还是旧的」那一类现象的根因（见 M16P9）。
            let bundleReplaced = !source.usedCache
            let snapshot = try await service.sites(forceRestartHost: forceRestart || bundleReplaced)
            hostSites = snapshot.sites
            // 刚拿到清单 = 宿主现在活着（省掉一次探活）。
            hostHealth = .online
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
    func restartHost() async {
        guard let source = state.loadedSource, source.kind == .javaScript else {
            return
        }
        await refreshHost(for: source, forceRestart: true)
        // 宿主重启会换掉站点清单（端口、站点集合都可能变）：首页/搜索据此作废旧内容。
        bumpSiteCatalogRevision()
    }

    /// 刷一次「站点 `POST /init` 失败清单」（M16P10）：接口页进页面时调，展示在「Node 宿主」区块里。
    ///
    /// 为什么放在宿主那一段：init 是宿主契约的一步，失败原因跟宿主状态放一起看最省事
    /// （M16P6 当时留的口子就是这个）。
    func refreshSiteInitFailures() async {
        siteInitFailures = await spiderInitializer.failureNotes()
    }

    /// 停止宿主并清空宿主站点。
    func stopHost() async {
        await js2pHost?.stop()
        js2pHost = nil
        hostSites = []
        hostStatus = .idle
        hostHealth = .unknown
        bumpSiteCatalogRevision()
    }

    /// 探一次宿主**现在**是否还活着（M22P1）：`GET /health`，几毫秒的事。
    ///
    /// 没有宿主时给 `.unknown`（不是 `offline` —— 那不叫离线，那叫「当前接口不需要宿主」）。
    func refreshHostHealth() async {
        guard let host = js2pHost else {
            hostHealth = .unknown
            return
        }
        hostHealth = await host.health() ? .online : .offline
    }

    /// 宿主落盘日志路径（没有落盘能力时为 nil）。
    ///
    /// 日志开关（``AppModel/isEngineLogEnabled``）决定宿主是否把输出写文件；
    /// 「设置 → 数据 → 日志管理 → 导出」用它拿到要导出的内容。
    func hostLogPath() async -> URL? {
        await js2pHost?.hostLogPath()
    }

    /// 宿主最近输出：内存里的尾部 + 落盘日志的尾部（见 ``JS2PHostService``）。
    ///
    /// 「源地址 → Node 宿主 → 查看宿主输出」与「设置 → 数据 → 日志管理」共用它；
    /// 没有宿主（未加载 JS 源 / 平台不支持）时返回空数组，界面据此显示「暂无输出」。
    func hostDiagnostics(limit: Int = 20) async -> [String] {
        guard let host = js2pHost else {
            return []
        }
        return await host.hostDiagnostics(limit: limit)
    }

    /// 把日志开关应用到正在运行的宿主。
    ///
    /// 宿主不能重建（内嵌 node 每进程只能起一个实例），所以开关必须能**运行中改**；
    /// 宿主还没起来时什么都不做 —— 下次 ``refreshHost(for:forceRestart:)`` 会带上当前值。
    internal func applyLogPreferenceToHost() {
        guard let host = js2pHost else {
            return
        }
        Task {
            await host.setLogPersistence(isEngineLogEnabled)
        }
    }
}
