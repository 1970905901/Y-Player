import CatVodCore
import Foundation

/// 「网页条目」：点了**不该进详情页**、而该打开网页的条目。
///
/// 为什么要有这条规则：js2p 宿主的「配置|中心」站点返回的就是这种条目 ——
/// 它的 `vod_id`（`config-center`）既不是线路也不是 vodID，详情接口里什么都没有，
/// 点进去只能是一片空白；用户真正要看的是宿主那个配置网页。
enum WebEntryRules {
    /// 条目要点开的网址；`nil` = 普通条目（照旧走详情页）。
    ///
    /// 两类判定（**都按数据判，不写死站点 key**）：
    /// 1. `vod_id` 自己就是 http(s) 地址 —— 上游存在「条目即网页」的写法；
    /// 2. `vod_id == "config-center"` —— 宿主配置中心那个按钮。实测返回体是
    ///    `{"vod_id":"config-center","vod_name":"扫码配置","vod_remarks":"点击打开配置中心"}`，
    ///    分类名给的正是 `http://127.0.0.1:<port>/website`；地址这里用**站点 api 的 scheme + host**
    ///    拼 `/website`（与 bundle 自己给的地址一致，不去解析分类名 —— 那个字段是给人看的）。
    static func webURL(for item: VodItem, site: Site?) -> URL? {
        let raw = item.vodID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            return url
        }
        guard raw == configCenterID,
              let site,
              let api = URL(string: site.api),
              let host = api.host
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = api.scheme ?? "http"
        components.host = host
        components.port = api.port
        components.path = "/website"
        return components.url
    }

    /// 宿主配置中心那个「按钮」条目的 `vod_id`（bundle 实测值）。
    static let configCenterID = "config-center"
}

/// 已经确认要打开的网页。
///
/// 单独一个类型：（`.sheet(item:)` 需要 `Identifiable`，而 `URL` 不是）。
struct WebEntry: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}
