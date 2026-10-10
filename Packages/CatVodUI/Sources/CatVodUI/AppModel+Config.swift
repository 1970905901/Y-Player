import CatVodCore
import CatVodSource
import Foundation

// 「配置 → 站点清单」这一组：当前可用 / 全部站点、配置告警、多配置入口与切换加载。
//
// 为什么放扩展文件：AppModel 主体的类型体行数（`type_body_length`）离 CI 的 error 线（450）只剩几行；
// 这一组只读 `state` / `hostSites` 与公开加载入口，搬出来零成本
// （与 `AppModel+Cache.swift`（缓存）、`AppModel+Storage.swift`（落库）同一套切分方式）。

extension AppModel {
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

    /// 配置里的**多配置入口**（`urls`，多仓）：去掉空项 + 按当前配置地址解析相对路径（M18P2）。
    ///
    /// 界面两处用它：源地址页列出来让用户点（``loadSubConfig(_:)``），以及
    /// 发现页在「站点为空」时说清原因 —— 而不是让用户以为配置没生效。
    /// 可见性刻意是「模块内」：`ConfigSubURLEntry` 是本模块类型，而 public 位置不能用 internal 类型
    /// （编译期直接拦，同一类错踩过三次了 —— 见 M10h / M17P1）。
    var configSubURLEntries: [ConfigSubURLEntry] {
        ConfigSubURLs.entries(state.loadedSource?.config.urls ?? [], relativeTo: state.loadedSource?.originURL)
    }

    /// 用多仓里的一条子配置**替换当前接口地址并加载**。
    ///
    /// 与用户在地址框里手填是**同一条路**：加载完当前配置就是那条子配置（地址框里也是它）——
    /// 不另立「多仓状态」，想回仓库那份就把仓库地址再填一次。`url == nil` 的条目不动。
    func loadSubConfig(_ entry: ConfigSubURLEntry) async {
        guard let url = entry.url else {
            return
        }
        configURL = url.absoluteString
        await load(forceRefresh: true)
    }

    public var loadedKind: LoadedSource.Kind? {
        state.loadedSource?.kind
    }
}
