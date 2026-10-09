import Foundation

/// 配置项覆盖报告：把「解析进来了、但本平台不生效」的字段如实列出来。
///
/// ## 为什么要有它
///
/// 这些字段早就被 ``SourceConfig`` 认真解析进模型（`init(from:)` 里逐个 `lenientArray` /
/// `lenientStringArray`），但**全仓没有一个消费方** —— 字段读进来了，配置写了等于白写。
///
/// 两类原因，都在这里报，但成因不同：
///
/// - **平台缺口**：`doh` / `hosts`。上游能这么做是因为它跑在 OkHttp 上，而 OkHttp 暴露了 `Dns`
///   接口（换掉解析器就是十几行）；Apple 侧的 `URLSession` **没有对应钩子**，要做到得自建连接层
///  （见 `docs/任务记录/M06m-DNS方案与决策.md`）。这是**差异**，不是偷懒 ——
///   但差异必须说出来：配置里写了 `hosts` 却不生效，用户只会以为「这个站不行」。
/// - **还没接的界面**：`flags`（上游的播放 flag 菜单）、`logo`、`notice`。
///   这些是能做的，只是当前没有消费方；同样要报，免得用户以为配置没生效是自己的问题。
/// - **有意不做**：`wallpaper`（首页壁纸）—— 首页形态（WebHome）早已决定不做，壁纸无处可用。
///   它**不是**「还没接」，别再当待办（这次差点按待接界面去做，被指出后才发现矩阵里写着不做）。
///
/// 所以这里的职责只有一个：**列出不生效的字段与原因**，交给界面原样显示。
/// 它不做任何解析或请求，也不假装支持。
public enum ConfigCoverage {
    /// 一个有值、但本平台不生效的字段。
    public struct Ignored: Sendable, Equatable, Hashable {
        /// 配置里的键名（与 JSON 一致，便于用户回去对照）。
        public let key: String
        /// 界面上的中文名。
        public let title: String
        /// 为什么不生效（一句话，写给用户看）。
        public let reason: String

        public init(key: String, title: String, reason: String) {
            self.key = key
            self.title = title
            self.reason = reason
        }
    }

    /// `hosts` 覆盖为什么做不到：需要在建立连接前换掉解析结果。
    public static let hostsReason = "本平台没有可用的 DNS 钩子：URLSession 不支持按需改写解析结果，规则不会生效"

    /// `doh` 为什么做不到：DoH 要先能自己发 DNS 查询，前提与 `hosts` 相同。
    public static let dohReason = "同上：DoH 需要先能自建解析与连接，URLSession 做不到，规则不会生效"

    /// `flags`：上游把它做成播放页的 flag 选择菜单（配套 `FlagSelectionListener`），本平台没有这个菜单。
    public static let flagsReason = "本平台没有播放 flag 选择菜单，这份列表不会生效（站点详情自带的 flag 可正常切换）"

    /// `wallpaper`：上游是首页壁纸（`wall` / `getWall()`）。**本平台有意不做**，不是「还没接」——
    /// 首页形态（WebHome）早已决定不做（见 `docs/协议兼容矩阵.md`），壁纸无处可用。
    /// 别再把它当待办（这次就差点按「待接界面」去做，被指出后才发现矩阵里写着不做）。
    public static let wallpaperReason = "本平台没有网页首页形态（WebHome 已决定不做），配置里的壁纸无处可用"

    /// `logo`：配置图标。
    public static let logoReason = "本平台不使用配置图标"

    /// `notice`：配置公告。
    public static let noticeReason = "本平台不显示配置公告"

    /// 挑出配置里「有值、但本平台不生效」的字段。
    ///
    /// 顺序跟 ``SourceConfig`` 的字段声明顺序一致（`doh` → `hosts` → `flags` → `wallpaper` → `logo` →
    /// `notice`），界面与测试都依赖这个顺序。
    public static func ignored(in config: SourceConfig) -> [Ignored] {
        var result: [Ignored] = []
        if !config.doh.isEmpty {
            result.append(Ignored(key: "doh", title: "DoH 解析", reason: dohReason))
        }
        if !config.hosts.isEmpty {
            result.append(Ignored(key: "hosts", title: "host 覆盖", reason: hostsReason))
        }
        if !config.flags.isEmpty {
            result.append(Ignored(key: "flags", title: "播放 flag 列表", reason: flagsReason))
        }
        if !config.wallpaper.isEmpty {
            result.append(Ignored(key: "wallpaper", title: "首页壁纸", reason: wallpaperReason))
        }
        if !config.logo.isEmpty {
            result.append(Ignored(key: "logo", title: "配置图标", reason: logoReason))
        }
        if !config.notice.isEmpty {
            result.append(Ignored(key: "notice", title: "配置公告", reason: noticeReason))
        }
        return result
    }
}
