import CatVodCore
import CatVodSource
@testable import CatVodUI
import Testing

/// 字幕接线的纯逻辑部分（M09c）：请求的「空判定」与状态行文案。
///
/// 状态行是会反复出现在播放页的一句话，「加载中」和「没搜到」混了会让用户以为一直卡着 ——
/// 与弹幕的状态行同理，所以单独钉住。
@Suite("字幕接线（纯逻辑）")
struct SubtitlePlaybackTests {
    private func source(_ url: String, name: String = "", language: String = "") -> SubtitleSource {
        SubtitleSource(name: name, url: url, language: language, format: "")
    }

    @Test("请求为空：源全是空地址 → 界面不该触发请求")
    func emptyRequest() {
        #expect(SubtitleRequest(sources: []).isEmpty)
        #expect(SubtitleRequest(sources: [source(""), source("   ")]).isEmpty)
        #expect(!SubtitleRequest(sources: [source(""), source("https://a/1.srt")]).isEmpty)
    }

    @Test("展示名逐级回落：`name` → `language` → `url`")
    func displayNameFallsBack() {
        #expect(source("https://a/1.srt", name: "简中").displayName == "简中")
        #expect(source("https://a/1.srt", language: "zh").displayName == "zh")
        #expect(source("https://a/1.srt").displayName == "https://a/1.srt")
    }

    @Test("状态行文案：五种状态各自说清，不混")
    func statusTexts() {
        #expect(SubtitleStatus.idle.text.isEmpty)
        #expect(SubtitleStatus.loading.text == "正在加载字幕…")
        #expect(SubtitleStatus.empty.text.contains("没有给出"))
        #expect(SubtitleStatus.loaded(source: "简中", count: 42).text == "字幕：简中 · 42 条")
        #expect(SubtitleStatus.failed(reason: "连不上").text.contains("连不上"))
    }
}
