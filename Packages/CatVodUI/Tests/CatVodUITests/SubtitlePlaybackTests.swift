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

    @Test("该显示哪份字幕：内嵌优先 / 关闭谁都不显示 / 其余用外部（M04P19）")
    @MainActor
    func effectiveCues() {
        let embedded = [SubtitleCue(start: 0, end: 1, text: "内嵌")]
        let external = [SubtitleCue(start: 0, end: 1, text: "外部")]

        // 选了内嵌轨：内嵌优先（外部那份不混进来）
        let pickEmbedded = PlaybackView.effectiveSubtitleCues(
            embedded: embedded, external: external, selection: .auto
        )
        #expect(pickEmbedded == embedded)

        // 用户明确关掉：谁都不显示（与 MPV 的 sid=no 同口径）
        let offWithEmbedded = PlaybackView.effectiveSubtitleCues(
            embedded: embedded, external: external, selection: .disabled
        )
        #expect(offWithEmbedded.isEmpty)
        let offExternalOnly = PlaybackView.effectiveSubtitleCues(
            embedded: [], external: external, selection: .disabled
        )
        #expect(offExternalOnly.isEmpty)

        // 没选内嵌：用外部那份（自动 / 指定外部轨都算）
        let plain = PlaybackView.effectiveSubtitleCues(embedded: [], external: external, selection: .auto)
        #expect(plain == external)
        let byIndex = PlaybackView.effectiveSubtitleCues(embedded: [], external: external, selection: .index(3))
        #expect(byIndex == external)
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
