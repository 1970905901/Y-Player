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
        notice: String = ""
    ) -> SourceConfig {
        var config = SourceConfig()
        config.doh = doh
        config.hosts = hosts
        config.flags = flags
        config.wallpaper = wallpaper
        config.logo = logo
        config.notice = notice
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

    @Test("四个「还没接界面」的字段：有值就报，顺序与声明一致")
    func reportsUnwiredFields() {
        let filled = config(
            flags: ["youku", "qq"],
            wallpaper: "https://img.example/w.jpg",
            logo: "https://img.example/logo.png",
            notice: "配置公告"
        )
        let ignored = ConfigCoverage.ignored(in: filled)
        #expect(ignored.map(\.key) == ["flags", "wallpaper", "logo", "notice"])
        #expect(ignored.map(\.reason) == [
            ConfigCoverage.flagsReason,
            ConfigCoverage.wallpaperReason,
            ConfigCoverage.logoReason,
            ConfigCoverage.noticeReason,
        ])
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
            notice: "公告"
        )
        let coverage = filled.validationWarnings.filter { $0.contains("在本平台不生效") }
        #expect(coverage.count == 6)
        for key in ["`doh`", "`hosts`", "`flags`", "`wallpaper`", "`logo`", "`notice`"] {
            #expect(coverage.contains { $0.contains(key) })
        }

        // 没填就不该有这一条（避免噪音）
        #expect(config().validationWarnings.allSatisfy { !$0.contains("在本平台不生效") })
    }
}
