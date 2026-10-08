@testable import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

/// AppModel 集成（内联配置 + 临时存档）—— 专门覆盖那些**之前只能靠调用点审查**的接线。
///
/// 这一套的价值不在「再测一遍纯逻辑」（那些各自有单测），而在验「接起来了没有」：
/// 改名有没有真的换掉分组标签、开关规则有没有立刻反映到 `siteGroups`、统计归零有没有落到提示上。
@Suite("AppModel 集成（内联配置）")
@MainActor
struct AppModelIntegrationTests {
    @Test("内联配置能载入：站点与分组条都出来了")
    func loadsInlineConfig() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load()

        #expect(fixture.model.sites.count == 2)
        #expect(fixture.model.siteGroups == ["主力", "4K", "首页"])
        #expect(fixture.model.siteGroupRuleEntries.count == GroupRuleConfig.builtins.count)
    }

    @Test("改名（M06f）：显示名换掉、旧标签跟着消失、恢复原名能回去")
    func renameSite() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()
        let site = try #require(fixture.model.sites.first { $0.key == "a" })

        fixture.model.renameSite(site, to: "我的甲站")
        #expect(fixture.model.siteDisplayName(for: site) == "我的甲站")
        #expect(fixture.model.siteGroups == ["首页"])

        fixture.model.renameSite(site, to: "")
        #expect(fixture.model.siteDisplayName(for: site) == "[主力]甲站|4K")
        #expect(fixture.model.siteGroups == ["主力", "4K", "首页"])
    }

    @Test("规则开关（M06g）：关掉内置竖线规则 → 4K 分组立刻消失；再打开又回来")
    func toggleBuiltinRule() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        fixture.model.toggleSiteGroupRule(GroupRuleConfig.builtinPipe)
        #expect(fixture.model.siteGroups == ["主力", "首页"])
        #expect(fixture.model.disabledSiteGroupRuleIDs == [GroupRuleConfig.builtinPipe])

        fixture.model.toggleSiteGroupRule(GroupRuleConfig.builtinPipe)
        #expect(fixture.model.siteGroups == ["主力", "4K", "首页"])
    }

    @Test("自建规则（M06g）：加一条 → 标签进分组条；删掉 → 连它的开关记录一起清掉")
    func userRuleLifecycle() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        #expect(fixture.model.addSiteUserRule(name: "波浪号", regex: "~(.+)$"))
        #expect(!fixture.model.addSiteUserRule(name: "波浪号", regex: "~(.+)$")) // 同一条不重复加
        #expect(!fixture.model.addSiteUserRule(name: "坏", regex: "(")) // 编不出来不存
        let rule = try #require(fixture.model.siteGroupRuleEntries.first { $0.rule.source == GroupRule.sourceUser })

        fixture.model.toggleSiteGroupRule(rule.rule.id)
        #expect(fixture.model.disabledSiteGroupRuleIDs.contains(rule.rule.id))

        fixture.model.removeSiteUserRule(rule.rule.id)
        #expect(!fixture.model.disabledSiteGroupRuleIDs.contains(rule.rule.id))
        #expect(!fixture.model.siteGroupRuleEntries.contains { $0.rule.source == GroupRule.sourceUser })
    }

    @Test("分组顺序（M06e）：上移一格会落到存档里，重排后站点集合不变")
    func moveSiteGroupPersists() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        fixture.model.moveSiteGroup("首页", direction: -1)

        // 上移一位：`[主力, 4K, 首页]` → `[主力, 首页, 4K]`
        #expect(fixture.model.siteGroupOrder == ["主力", "首页", "4K"])
        #expect(fixture.model.siteGroups == ["主力", "首页", "4K"])
    }

    @Test("跳过广告（M06k/M06l）：统计落到提示上，归零时提示也清")
    func adSkipNoticeFollowsStats() throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        fixture.model.applyAdSkip(AdSkipRecorder.Stats(cleanedPlaylists: 2, removedSegments: 3, removedDurationSec: 12))
        #expect(fixture.model.adSkipNotice == "已跳过广告 3 段，约 12 秒")

        fixture.model.resetAdSkip()
        #expect(fixture.model.adSkipNotice.isEmpty)
        #expect(fixture.model.adSkipRecorder.stats == AdSkipRecorder.Stats())
    }

    @Test("广告清理规则（M06d/M06h）：配置载入后规则进了 store，关掉开关后 store 也空")
    func hlsAdRuleWiring() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load("""
        {"sites":[],
         "hlsRules":[{"id":"builtin.test.v1","name":"示例","enabled":true,
                      "playlistHostSuffixes":["video.example.com"],
                      "hostSuffixes":["ads.example.com"],"minimumSignals":1}]}
        """)

        // 接口写了 enabled=true → 编出来进 store（`/m3u8` 每请求现读这里）
        let entries = fixture.model.hlsAdRuleEntries
        #expect(entries.count == 1)
        #expect(entries.first?.isEnabled == true)
        #expect(fixture.model.adRuleStore.current.count == 1)

        // 本地关掉 → 立刻重算：列表变、store 也空
        let key = try #require(entries.first?.key)
        fixture.model.setHLSAdRule(key, enabled: false)
        #expect(fixture.model.hlsAdRuleEntries.first?.isEnabled == false)
        #expect(fixture.model.adRuleStore.current.isEmpty)

        // 恢复默认（nil）= 回到接口的写法
        fixture.model.setHLSAdRule(key, enabled: nil)
        #expect(fixture.model.hlsAdRuleEntries.first?.isEnabled == true)
        #expect(fixture.model.adRuleStore.current.count == 1)
    }

    @Test("弹幕（M08c）：开关关着 / 没填地址时**不发请求**且不显示状态行")
    func danmakuGuardsDoNotFetch() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.model.loadDanmaku(DanmakuRequest(name: "片名", episode: "第1集"))
        #expect(fixture.model.danmakuStatus == .idle)
        #expect(fixture.model.danmakuLines.isEmpty)

        fixture.model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["", ""])
        await fixture.model.loadDanmaku(DanmakuRequest(name: "片名", episode: "第1集"))
        #expect(fixture.model.danmakuStatus == .idle)
    }
}
