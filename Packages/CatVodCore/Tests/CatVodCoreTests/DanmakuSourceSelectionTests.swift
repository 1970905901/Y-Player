import CatVodCore
import Testing

/// 弹幕源选取（M09e）：站点结果自带优先，其次 API 搜索 —— 对齐上游 `isSpiderFirst`。
///
/// 抽成纯函数就是为了这一组测试：真正下载弹幕文件那一步在测试里跑不了（离线），
/// 但「该用哪个源」这个判断能单独钉住。
@Suite("弹幕源选取")
struct DanmakuSourceSelectionTests {
    private func source(_ url: String, name: String = "") -> DanmakuSource {
        DanmakuSource(name: name, url: url)
    }

    @Test("结果自带可用源：用它，并标明来源是结果")
    func prefersResult() throws {
        let selection = try #require(DanmakuSourceSelection.preferred(
            result: [source("https://result/1.xml", name: "站点源")],
            api: [source("https://api/1.xml", name: "搜索源")]
        ))

        #expect(selection.source.url == "https://result/1.xml")
        #expect(selection.isFromResult)
    }

    @Test("结果自带的地址是空的：回退到 API 搜索")
    func fallsBackToSearch() throws {
        let selection = try #require(DanmakuSourceSelection.preferred(
            result: [source("", name: "占位"), source("   ")],
            api: [source("https://api/1.xml", name: "搜索源")]
        ))

        #expect(selection.source.url == "https://api/1.xml")
        #expect(!selection.isFromResult)
    }

    @Test("两边都没有可用源：nil（界面据此不显示状态行）")
    func nothingUsable() {
        #expect(DanmakuSourceSelection.preferred(result: [], api: []) == nil)
        #expect(DanmakuSourceSelection.preferred(result: [source("")], api: [source("  ")]) == nil)
    }

    @Test("结果自带多个：取第一条可用的")
    func takesFirstUsable() throws {
        let selection = try #require(DanmakuSourceSelection.preferred(
            result: [source(""), source("https://result/2.xml", name: "第二个")],
            api: []
        ))

        #expect(selection.source.url == "https://result/2.xml")
    }
}
