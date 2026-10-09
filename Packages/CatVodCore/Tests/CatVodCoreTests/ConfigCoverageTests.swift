import CatVodCore
import Testing

/// `ConfigCoverage`：**有值才报**，且报出来的字段确实没有消费方（见类型注释里的原因）。
@Suite("配置项覆盖报告")
struct ConfigCoverageTests {
    private func config(
        doh: [DohConfig] = [],
        hosts: [String] = [],
        flags: [String] = [],
        wallpaper: String = "",
        logo: String = "",
        notice: String = "",
        urls: [String] = []
    ) -> SourceConfig {
        var config = SourceConfig()
        config.doh = doh
        config.hosts = hosts
        config.flags = flags
        config.wallpaper = wallpaper
        config.logo = logo
        config.notice = notice
        config.urls = urls
        return config
    }

    @Test("干净配置：没有要报的不生效字段")
    func cleanConfigReportsNothing() {
        #expect(ConfigCoverage.ignored(in: config()).isEmpty)
    }

    @Test("填了 hosts 就报，带上键名与原因")
    func reportsHosts() {
        let ignored = ConfigCoverage.ignored(in: config(hosts: ["a.example.com=1.2.3.4"]))
        #expect(ignored.count == 1)
        #expect(ignored.first?.key == "hosts")
        #expect(ignored.first?.reason == ConfigCoverage.hostsReason)
    }

    @Test("doh 与 hosts 都填：顺序按 `SourceConfig` 的字段声明")
    func reportsPlatformGaps() {
        let ignored = ConfigCoverage.ignored(in: config(doh: [DohConfig()], hosts: ["a=1.2.3.4"]))
        #expect(ignored.map(\.key) == ["doh", "hosts"])
    }

    @Test("三个「还没接界面」的字段：有值就报，顺序与声明一致")
    func reportsUnwiredFields() {
        let filled = config(
            wallpaper: "https://img.example/w.jpg",
            logo: "https://img.example/logo.png",
            notice: "配置公告"
        )
        let ignored = ConfigCoverage.ignored(in: filled)
        #expect(ignored.map(\.key) == ["wallpaper", "logo", "notice"])
        // 先绑变量再断言：`#expect` 里「map + 多行数组字面量」的宏展开在个别工具链版本上会失败。
        let reasons = ignored.map(\.reason)
        #expect(reasons == [
            ConfigCoverage.wallpaperReason,
            ConfigCoverage.logoReason,
            ConfigCoverage.noticeReason,
        ])
    }

    @Test("多配置入口（`urls`）要报：不报的话多仓配置只会显示「没有可用站点」")
    func reportsMultipleConfigEntryPoints() {
        let ignored = ConfigCoverage.ignored(in: config(urls: ["https://a.example/1.json", "https://b.example/2.json"]))
        #expect(ignored.map(\.key) == ["urls"])
        #expect(ignored.first?.reason == ConfigCoverage.urlsReason)
        // 空数组不算「填了」
        #expect(ConfigCoverage.ignored(in: config(urls: [])).isEmpty)
    }

    @Test("`flags` 不再报：它已接进解析判定（M09h 查清它的语义是 vipFlags，不是「flag 菜单」）")
    func flagsIsNoLongerReported() {
        let withFlags = config(flags: ["youku", "qq"])
        #expect(ConfigCoverage.ignored(in: withFlags).isEmpty)
        // 闭包先挪到 `#expect` 外面：宏里带闭包容易展开失败，绑成 Bool 再断言。
        let hasFlagsWarning = withFlags.validationWarnings.allSatisfy { !$0.contains("`flags`") }
        #expect(hasFlagsWarning)
    }

    @Test("字段存在但是空（`[]` / `\"\"`）：不算「填了」，不报")
    func reportsOnlyWhenNonEmpty() {
        #expect(ConfigCoverage.ignored(in: config(doh: [], hosts: [], flags: [], wallpaper: "")).isEmpty)
        #expect(ConfigCoverage.ignored(in: config(logo: "", notice: "")).isEmpty)
    }

    @Test("这些条目会进 `validationWarnings` ——「接口管理 → 告警」里看得见")
    func reachesValidationWarnings() {
        let filled = config(
            doh: [DohConfig()],
            hosts: ["a=1.2.3.4"],
            flags: ["youku"],
            wallpaper: "https://img.example/w.jpg",
            logo: "https://img.example/l.png",
            notice: "公告",
            urls: ["https://a.example/1.json"]
        )
        let coverage = filled.validationWarnings.filter { $0.contains("在本平台不生效") }
        #expect(coverage.count == 6)
        for key in ["`doh`", "`hosts`", "`wallpaper`", "`logo`", "`notice`", "`urls`"] {
            #expect(coverage.contains { $0.contains(key) })
        }
        // `flags` 有值也不该出现：它已经接进解析判定，不再是「不生效的字段」
        #expect(!coverage.contains { $0.contains("`flags`") })

        // 没填就不该有这一条（避免噪音）
        let nothingIgnored = config().validationWarnings.allSatisfy { !$0.contains("在本平台不生效") }
        #expect(nothingIgnored)
    }
}
