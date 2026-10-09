import Foundation

/// 会话事件 / 属性 → 播放语义的**纯映射**（CI 能验的那半的核心）。
///
/// 这里不碰 libmpv、不碰真机：给定「哪个属性变成了什么值」，输出「引擎该改什么状态、发什么事件」。
/// 映射写错了单测立刻红 —— 这正是把渲染路径（第 3 步，必须 Mac/真机）与语义（现在就能钉住）分开的意义。
public enum MpvEventMapping {
    /// 我们 observe 的属性 id（自己定的，回传时用来区分；libmpv 只要求非 0 且互不相同）。
    public static let timePositionID: UInt64 = 1
    public static let durationID: UInt64 = 2
    public static let pausedID: UInt64 = 3

    /// 要 observe 的 id 列表（引擎按它逐个 observe）。
    public static var observedIDs: [UInt64] {
        [timePositionID, durationID, pausedID]
    }

    /// 属性名（`mpv_observe_property` 的第一个参数）。
    public static func propertyName(for id: UInt64) -> String? {
        switch id {
        case timePositionID: "time-pos"
        case durationID: "duration"
        case pausedID: "pause"
        default: nil
        }
    }

    /// 属性格式（mpv 的字符串形式：`double` / `flag` / `int64` / `string`）。
    public static func propertyFormat(for id: UInt64) -> String? {
        switch id {
        case timePositionID, durationID: "double"
        case pausedID: "flag"
        default: nil
        }
    }

    /// `end-file` 的 reason 算不算失败。
    ///
    /// 只有 `error` 算：其余（`eof` / `stop` / `quit` / `redirect` / 未知）都归到「结束」——
    /// `stop` / `quit` 是我们自己 teardown / 换片时 mpv 报的，不该对用户说「播放失败」。
    public static func isFailure(endFileReason reason: String) -> Bool {
        reason == "error"
    }

    /// 从 `track-list` 的 JSON 里挑出三类轨道的 id。
    ///
    /// mpv 的 `track-list` 读成字符串就是 JSON：
    /// `[{"id":1,"type":"video",…},{"id":2,"type":"audio","default":true,…},{"id":3,"type":"sub",…}]`。
    /// 只认 `video` / `audio` / `sub`；**封面图轨道**（`albumart == true` 的 video）要排除 ——
    /// 它会让用户在「音轨」里看见一条没有声音的假轨道。
    ///
    /// 解析不了（不是数组 / 没有 id 与 type）返回 nil：调用方据此**什么都不发**，别发一个空列表
    /// 把界面上的选择清空。
    public static func trackIDs(fromTrackListJSON json: String) -> (video: [Int], audio: [Int], subtitle: [Int])? {
        guard let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }
        var video: [Int] = []
        var audio: [Int] = []
        var subtitle: [Int] = []
        for entry in list {
            guard let id = entry["id"] as? Int, let type = entry["type"] as? String else {
                continue
            }
            switch type {
            case "video":
                // 封面图不是画面轨道（mpv 会把它当 video 轨道报出来）。
                if entry["albumart"] as? Bool == true {
                    continue
                }
                video.append(id)
            case "audio":
                audio.append(id)
            case "sub":
                subtitle.append(id)
            default:
                continue
            }
        }
        return (video, audio, subtitle)
    }

    /// 等待事件时每轮最多阻塞多久（秒）。
    ///
    /// 取值理由：`mpv_wait_event` 是阻塞调用，而它跑在 `MpvEngine` 这个 actor 里 ——
    /// 阻塞越久，`pause()` / `seek()` 这些命令等得越久。0.05s 是「不空转太多」与「命令不卡手」的折中。
    public static let eventWaitTimeout: Double = 0.05

    /// 属性变化 → 引擎该做的动作。
    ///
    /// 三条语义（都有单测）：
    /// - `time-pos` → 发 `timeChanged(current:duration:)`（时长用引擎当前记着的那个）；
    /// - `duration` → 记下来并发一条 `timeChanged`（进度条要立刻能画）；
    /// - `pause` → 改状态（`.paused` / `.playing`）；
    /// - 负值、类型对不上、不是我们 observe 的 id → `.ignore`（libmpv 在某些状态下会给「暂时没有值」）。
    public static func effect(
        ofProperty id: UInt64,
        value: MpvPropertyValue,
        duration: Double
    ) -> MpvPropertyEffect {
        switch id {
        case timePositionID:
            guard let seconds = value.doubleValue, seconds >= 0 else {
                return .ignore
            }
            return .time(current: seconds, duration: duration)
        case durationID:
            guard let seconds = value.doubleValue, seconds >= 0 else {
                return .ignore
            }
            return .duration(seconds)
        case pausedID:
            guard let paused = value.boolValue else {
                return .ignore
            }
            return .paused(paused)
        default:
            return .ignore
        }
    }
}

/// 属性变化带来的效果（引擎照着改状态 / 发事件；纯值，好断言）。
public enum MpvPropertyEffect: Equatable, Sendable {
    /// 播放位置变了。
    case time(current: Double, duration: Double)
    /// 时长变了（引擎记下来，并补一条 `timeChanged`）。
    case duration(Double)
    /// 暂停开关变了。
    case paused(Bool)
    /// 与我们无关（或值暂时不可用）：什么都不做。
    case ignore
}
