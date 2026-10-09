import CatVodCore
import CatVodPlayer
import CatVodSource
import Foundation

// 「播放设置」的接线：内核/解码方式的可用性判定与提示文案。
//
// 为什么放扩展文件：`AppModel` 主体的职责是「配置 / 站点 / 直播」的状态，播放内核的判定与提示是
// 另一件事 —— 与 `AppModel+Cache.swift`（缓存）、`AppModel+Storage.swift`（落库）同一套切分方式；
// 顺带把类体长度压回 `type_body_length` 的上限内（SwiftLint 的 error 阈值是 450 行）。

public extension AppModel {
    /// 记下最近一次读到的播放信息（M17P2）：诊断报告的「最近播放」段就是它。
    ///
    /// 可见性是「模块内」：调用方是播放页与详情页那几个视图（都在本模块），
    /// 没必要把 `PlaybackStats` 这条回传口暴露到包外。
    internal func notePlaybackStats(_ stats: PlaybackStats) {
        lastPlaybackStats = stats
    }

    /// 严格解析播放内核（**不降级**）：不可用时返回原因，由 UI 提示用户修改设置。
    func resolvePlayback() -> PlayerEngineResolution {
        PlayerCoordinator().resolve(settings: playbackSettings)
    }

    /// 刷新播放提示：所选内核不可用、解码方式对所选内核无效等（如实告知，不静默处理）。
    ///
    /// 可见性是「模块内」而不是 `private`：`AppModel.swift` 的 `init` 与两个 `didSet` 都要调它
    /// （`private` 只对声明所在文件开放，跨文件调用会编译失败）。
    internal func refreshPlaybackNotice() {
        if case .javaScript = state.loadedSource?.kind {
            // JS 源的站点由内嵌 Node 宿主提供（macOS 可用）：宿主失败的原因在「接口管理 → Node 宿主」里显示，
            // 不再用一句「等 M1.6」把所有情况盖住。
            playbackNotice = ""
            return
        }
        var notes: [String] = []
        if case let .unavailable(_, reason) = resolvePlayback() {
            notes.append(reason)
        }
        if !playbackSettings.isDecoderModeEffective {
            notes.append("\(decoderMode.displayName)对\(preferredEngine.displayName)无效：系统播放器由系统自行决定解码方式")
        }
        playbackNotice = notes.joined(separator: "\n")
    }
}
