import CatVodCore
import CatVodNet
import CatVodSource
import Foundation

// 直播页（M07c-2）的状态与 IO。
//
// 与点播同一条链路：配置的 `lives` → `LiveRepository`（取清单 → 解析成带分组频道的源）
// → `LiveEPGRepository`（节目单：文件 / 接口两种形态，M07b 与 M07c 已落地）。
// 这里只做三件事：选源与选分组的持久化、清单与节目单的按需加载、把错误翻成一句人话。

@MainActor
public extension AppModel {
    /// 配置里的直播源（`SourceConfig.lives`）。
    var liveSources: [LiveSource] {
        state.loadedSource?.config.lives ?? []
    }

    /// 当前选中的直播源：`selectedLiveKey` 命中就用它，否则回落配置里的第一个。
    var selectedLiveSource: LiveSource? {
        let sources = liveSources
        guard !sources.isEmpty else {
            return nil
        }
        return sources.first { $0.name == selectedLiveKey } ?? sources.first
    }

    /// 已解析的清单（含分组与频道）；还没加载过时为 `nil`。
    var liveSource: LiveSource? {
        liveState.loadedSource
    }

    /// 当前选中的分组：按名字取，找不到就用清单里的第一个。
    var selectedLiveGroupObject: LiveGroup? {
        guard let source = liveSource, !source.groups.isEmpty else {
            return nil
        }
        return source.groups.first { $0.name == selectedLiveGroup } ?? source.groups.first
    }

    /// 某频道已拿到的节目单（没有就返回 `nil`，界面按「暂无节目」处理）。
    func liveGuide(for channel: LiveChannel) -> EPGGuide? {
        liveGuides[channel.epgID]
    }

    /// 加载选中源的清单。
    ///
    /// 已经是这个源的已解析结果就直接返回（``LiveRepository/load(_:)`` 自己也短路），
    /// `force` 用于界面上的「重新加载」。
    func loadLivePlaylist(force: Bool = false) async {
        guard let source = selectedLiveSource else {
            liveState = .failed("当前接口里没有直播源（配置的 `lives` 为空）")
            return
        }
        if !force, let loaded = liveState.loadedSource, loaded.name == source.name, !loaded.groups.isEmpty {
            return
        }
        // 换源时清掉节目单缓存：缓存按 `epgID` 存，换源后同一个 `epgID` 可能指向另一个频道。
        let previousName = liveState.loadedSource?.name
        liveState = .loading
        if previousName != source.name {
            liveGuides.removeAll()
            liveEPGNotice = ""
        }
        do {
            let repository = LiveRepository(transport: transportForConfiguration())
            let loaded = try await repository.load(source)
            liveState = .loaded(loaded)
        } catch {
            liveState = .failed(Self.liveMessage(error))
        }
    }

    /// 拉一个频道的节目单（接口形态按「昨天 / 今天 / 明天」逐频道拉；文件形态一次拿全源）。
    ///
    /// 失败**不当错误处理**：界面上这一行显示「暂无节目」就行，原因留在 ``liveEPGNotice``
    /// （上游 `fetchEpgDay` 也是吞掉异常，不让某个频道的节目单拖垮整页）。
    func loadLiveGuide(for channel: LiveChannel) async {
        guard let source = liveState.loadedSource else {
            return
        }
        do {
            let repository = LiveEPGRepository(transport: transportForConfiguration())
            let guide = try await repository.load(
                channel: channel,
                source: source,
                existing: liveGuides[channel.epgID]
            )
            liveGuides[channel.epgID] = guide
            liveEPGNotice = ""
        } catch {
            liveEPGNotice = Self.liveMessage(error)
        }
    }

    /// 错误 → 界面能读的一句话（``CatVodError`` 自带 `errorDescription`）。
    private static func liveMessage(_ error: Error) -> String {
        (error as? CatVodError)?.errorDescription ?? String(describing: error)
    }
}
