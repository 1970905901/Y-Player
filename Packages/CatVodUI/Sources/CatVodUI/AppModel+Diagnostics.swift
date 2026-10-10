import CatVodCore
import CatVodPlayer
import CatVodSource
import Foundation

// 一键诊断（M17P1）：把「出问题时我要看的那几样」采下来。
//
// 这一层只**采集**（谁是当前接口、缓存是哪天拉的、内核怎么配的、下载与宿主现在什么状态），
// 拼成文字在 `DiagnosticsReport.text` 里 —— 那边是纯函数，有单测。
//
// ⚠️ 这个 extension **不能写成 `public extension`**：`DiagnosticsReport` 是模块内类型
// （只给设置页的诊断区用），而 public extension 里的成员默认是 public，
// 「public 方法返回 internal 类型」编译器直接报错（M10h 那次踩的是同一个坑）。
// 真要把报告暴露给外部时，得连类型一起抬成 public。
extension AppModel {
    /// 采一份诊断快照。`now` 只为测试注入（默认就是此刻）。
    func diagnosticsReport(now: Date = Date()) async -> DiagnosticsReport {
        let cachedURL = state.loadedSource?.cachedURL
        let digest = (state.loadedSource?.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return await DiagnosticsReport(
            generatedAt: now,
            appVersion: Self.appVersionText,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            interfaceKind: Self.interfaceKindText(loadedKind),
            interfaceAddress: DiagnosticsReport.redactAddress(configURL),
            interfaceDigest: digest.isEmpty ? "" : String(digest.prefix(12)) + "…",
            interfaceCachedAt: Self.timestampText(CachedFileFacts.modifiedAt(of: cachedURL)),
            interfaceCacheSize: CachedFileFacts.size(of: cachedURL) ?? "",
            engine: playbackSettings.engine.displayName,
            decoder: playbackSettings.decoderMode.displayName,
            mpvAvailability: MpvAvailability.summary,
            ffmpegAvailability: FFmpegAvailability.summary,
            downloads: downloadSummaryText,
            hostStatus: hostStatus.summary,
            hostTail: hostDiagnostics(limit: 12),
            storageFailures: storageFailures,
            playbackRows: DiagnosticsReport.playbackRows(from: lastPlaybackStats)
        )
    }

    /// 下载队列一行：**只数数、不列任务** —— 任务名里是片名，贴出去就是内容泄露。
    var downloadSummaryText: String {
        guard !downloadTasks.isEmpty else {
            return "共 0 条"
        }
        let counts = Dictionary(grouping: downloadTasks, by: \.status).mapValues { $0.count }
        func count(_ status: DownloadTask.Status) -> Int {
            counts[status] ?? 0
        }
        return "共 \(downloadTasks.count) 条：下载中 \(count(.running)) · 排队 \(count(.waiting))"
            + " · 暂停 \(count(.paused)) · 完成 \(count(.finished)) · 失败 \(count(.failed))"
    }

    /// App 版本一行：`0.1.0 (1)`；读不到就空（报告那边统一写成「—」）。
    static var appVersionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        if !short.isEmpty, !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short.isEmpty ? build : short
    }

    /// 接口类型一行。
    static func interfaceKindText(_ kind: LoadedSource.Kind?) -> String {
        guard let kind else {
            return "未加载"
        }
        return kind == .javaScript ? "JS 源（js2p）" : "JSON 配置"
    }

    /// 时间戳（nil 给空串，交给报告统一写成「—」）。
    static func timestampText(_ date: Date?) -> String {
        guard let date else {
            return ""
        }
        return DiagnosticsReport.timestamp(date)
    }
}
