@testable import CatVodUI
import Foundation
import Testing

/// 配置公告（`SourceConfig.notice`）：显示、关掉、换了新公告再来一次、关掉的状态落盘。
@Suite("配置公告")
@MainActor
struct ConfigNoticeTests {
    /// 带公告与图标的最小可用配置（内联 JSON，不走网）。
    private static func config(notice: String, logo: String = "https://example.com/logo.png") -> String {
        """
        {"sites":[{"key":"a","name":"甲站","type":3,"api":"http://127.0.0.1:9988/spider/a"}],
         "notice":"\(notice)","logo":"\(logo)"}
        """
    }

    @Test("配置带了公告：没关过就显示；关掉后不再显示（但原文还在）")
    func noticeShowsUntilDismissed() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load(Self.config(notice: "本站已更换域名"))
        #expect(fixture.model.configNotice == "本站已更换域名")
        #expect(fixture.model.pendingConfigNotice == "本站已更换域名")

        fixture.model.dismissConfigNotice()
        #expect(fixture.model.pendingConfigNotice == nil)
        // 关掉的是"横幅"，不是原文：接口管理页里还要看得到
        #expect(fixture.model.configNotice == "本站已更换域名")
    }

    @Test("配置换了新公告：关过旧的不影响新的")
    func newNoticeShowsAgain() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load(Self.config(notice: "第一条公告"))
        fixture.model.dismissConfigNotice()
        #expect(fixture.model.pendingConfigNotice == nil)

        await fixture.load(Self.config(notice: "第二条公告"))
        #expect(fixture.model.pendingConfigNotice == "第二条公告")
    }

    @Test("关掉的状态落盘：重开模型仍然记得")
    func dismissalPersists() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load(Self.config(notice: "本站已更换域名"))
        fixture.model.dismissConfigNotice()
        #expect(fixture.model.dismissedConfigNotice == "本站已更换域名")

        let reopened = try fixture.reopenedModel()
        #expect(reopened.dismissedConfigNotice == "本站已更换域名")

        reopened.configURL = Self.config(notice: "本站已更换域名")
        await reopened.load()
        #expect(reopened.pendingConfigNotice == nil)
    }

    @Test("没有公告 / 只有空白：不显示，也关不出脏值")
    func blankNoticeIsNothing() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load(Self.config(notice: "   "))
        #expect(fixture.model.configNotice.isEmpty)
        #expect(fixture.model.pendingConfigNotice == nil)

        fixture.model.dismissConfigNotice()
        #expect(fixture.model.dismissedConfigNotice.isEmpty)
    }

    @Test("配置图标：有值就带出来，没有就是空串")
    func logoIsCarried() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load(Self.config(notice: "", logo: "https://example.com/logo.png"))
        #expect(fixture.model.configLogo == "https://example.com/logo.png")
        #expect(fixture.model.pendingConfigNotice == nil)

        await fixture.load(Self.config(notice: "", logo: "  "))
        #expect(fixture.model.configLogo.isEmpty)
    }
}
