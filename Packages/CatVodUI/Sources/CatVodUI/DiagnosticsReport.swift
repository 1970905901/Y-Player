import CatVodPlayer
import Foundation

/// 一键诊断报告的**纯数据 + 渲染**（M17P1）。
///
/// 为什么要有它：这几轮排查（js2p 旧版本、播放失败、下载不动）全靠用户截图、我再去猜是哪一层。
/// 一份文本里带上「环境 / 接口与摘要 / 播放设置 / 内核可用性 / 下载 / 宿主 / 失败记录」，
/// 复制粘贴就能定位，省掉来回问。
///
/// 两条硬规矩：
/// - **脱敏**：接口地址只留 `scheme://host[:port]/path`，查询串整体抹掉（里面常带 token）；
/// - **缺什么写「—」**：不编默认值 —— 这份报告的价值就在于别让人猜。
///
/// 渲染是纯函数（不碰文件、不碰网络），所以能单测；采集那一半在 ``AppModel/diagnosticsReport(now:)``。
struct DiagnosticsReport: Sendable, Equatable {
    var generatedAt: Date
    var appVersion: String
    var systemVersion: String
    var interfaceKind: String
    var interfaceAddress: String
    var interfaceDigest: String
    var interfaceCachedAt: String
    var interfaceCacheSize: String
    var engine: String
    var decoder: String
    var mpvAvailability: String
    var downloads: String
    var hostStatus: String
    var hostTail: [String]
    var storageFailures: [String]
    /// 「最近播放」的几行（空数组 = 这次启动还没播过）。
    var playbackRows: [PlaybackRow] = []

    /// 「最近播放」的一行：标题 + 值。
    struct PlaybackRow: Sendable, Equatable {
        var title: String
        var value: String
    }

    /// 报告正文：纯文本，直接进剪贴板。
    var text: String {
        var lines: [String] = [
            "Y-Player 诊断报告",
            "生成时间：\(Self.timestamp(generatedAt))",
            "App：\(Self.value(appVersion))",
            "系统：\(Self.value(systemVersion))",
            "",
            "【接口】",
            "类型：\(Self.value(interfaceKind))",
            "地址：\(Self.value(interfaceAddress))",
            "摘要：\(Self.value(interfaceDigest))",
            "拉取时间：\(Self.value(interfaceCachedAt))",
            "缓存大小：\(Self.value(interfaceCacheSize))",
            "",
            "【播放】",
            "内核：\(Self.value(engine))",
            "解码：\(Self.value(decoder))",
            "内核可用性：\(Self.value(mpvAvailability))",
            "",
        ]
        lines.append(contentsOf: playbackSection())
        lines.append(contentsOf: [
            "【下载】",
            Self.value(downloads),
            "",
            "【宿主】",
            "状态：\(Self.value(hostStatus))",
        ])
        if hostTail.isEmpty {
            lines.append("最近输出：（无）")
        } else {
            lines.append("最近输出：")
            lines.append(contentsOf: hostTail.map { "  \($0)" })
        }
        lines.append("")
        lines.append("【失败记录】")
        if storageFailures.isEmpty {
            lines.append("（无）")
        } else {
            lines.append(contentsOf: storageFailures.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// 「最近播放」段：**没有就明说**（这条最常被问：画质不对 / 卡顿），不给一个空行。
    private func playbackSection() -> [String] {
        var lines = ["【最近播放】"]
        if playbackRows.isEmpty {
            lines.append("（这次启动还没播过）")
        } else {
            lines.append(contentsOf: playbackRows.map { "\($0.title)：\($0.value)" })
        }
        lines.append("")
        return lines
    }

    /// 把内核报的播放信息摊成几行：**空的项不出现**（与播放页那一块同一口径）。
    static func playbackRows(from stats: PlaybackStats?) -> [PlaybackRow] {
        guard let stats, !stats.isEmpty else {
            return []
        }
        let candidates: [(title: String, value: String)] = [
            ("画面", stats.resolutionText),
            ("编码", stats.codecText),
            ("帧率", stats.fpsText),
            ("色彩", stats.dynamicRangeText),
            ("解码", stats.decodeText),
            ("码率", stats.bitrateText),
            ("丢帧", stats.dropText),
        ]
        return candidates
            .filter { !$0.value.isEmpty }
            .map { PlaybackRow(title: $0.title, value: $0.value) }
    }

    // MARK: - 脱敏与格式化（纯函数，单测覆盖）

    /// 地址脱敏：只留 `scheme://host[:port]/path`。
    ///
    /// **查询串整个抹掉**（`?token=…` 这种最常出现在接口地址里）；解析不出来或不是 http(s)
    /// （例如内联 JSON 配置）时**不返回原文**，只给一句说明 —— 宁可少给人看一行，也不泄露配置内容。
    static func redactAddress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "—"
        }
        guard var components = URLComponents(string: trimmed), components.scheme != nil else {
            return "（非 http 地址，已省略）"
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "（地址无法解析，已省略）"
    }

    /// 时间戳：固定 `yyyy-MM-dd HH:mm:ss`（跨机器比对用，不跟随区域设置的长短写法）。
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 空值统一写成「—」。
    private static func value(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}
