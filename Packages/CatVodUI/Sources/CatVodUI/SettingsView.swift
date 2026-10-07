import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 设置页（参考图 1 的「设置」Tab）。
///
/// 分区与顺序对齐参考图：源地址 / 首页 / 播放 / 数据 / iCloud 同步。
/// 每一项都是**导航行**，点进去才是具体设置页 —— 与系统设置一致的原生形态。
///
/// 诚实原则（`docs/UI 规范.md` + `docs/任务记录/M02P11-设置页与追剧页.md`）：
/// 有真实数据可接的项就接真实数据（源地址、展示方式、内核/解码、解析器清单、缓存、宿主日志）；
/// 尚未落地的项（播放页外观、下载管理、iCloud 同步）**保留入口，并在页内写明缺什么、属于哪个里程碑**，
/// 不做「点了没反应」的假开关。
@MainActor
public struct SettingsView: View {
    @ObservedObject private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            sourceSection
            homeSection
            playbackSection
            dataSection
            syncSection
        }
        .adaptiveListStyle()
        .navigationTitle("设置")
    }

    // MARK: - 源地址

    /// 源地址：大字段名 + 一行地址小字（对齐参考图的第一块）。
    ///
    /// 点进去是原来的 ``InterfaceManagementView``（粘贴地址 / 加载 / 强制刷新 / 站点清单 /
    /// 宿主状态 / 接口缓存），也就是说「接口管理」这个功能没有消失，只是换了入口位置。
    private var sourceSection: some View {
        Section("源地址") {
            NavigationLink {
                InterfaceManagementView(model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceName)
                    Text(sourceSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// 源名称。
    ///
    /// 猫源配置里没有「配置名」字段（只有 `logo`/`notice` 和站点名），所以这里**不编造名字**：
    /// 有远端地址就用它的 host，JS 源写「JS 源（js2p）」，内联配置写「内联配置」。
    private var sourceName: String {
        guard !trimmedConfigURL.isEmpty else {
            return "未配置源地址"
        }
        if let host = model.state.loadedSource?.originURL?.host, !host.isEmpty {
            return host
        }
        return model.loadedKind == .javaScript ? "JS 源（js2p）" : "内联配置"
    }

    /// 地址（或未配置 / 加载失败的说明）。
    private var sourceSummary: String {
        if let reason = model.state.failureReason {
            return "加载失败：\(reason)"
        }
        guard !trimmedConfigURL.isEmpty else {
            return "点这里粘贴猫源 JSON 配置地址，或 js2p 的 index.js 地址"
        }
        if model.state.isLoading {
            return "加载中…"
        }
        if trimmedConfigURL.hasPrefix("{") {
            return "内联 JSON 配置"
        }
        return trimmedConfigURL
    }

    private var trimmedConfigURL: String {
        model.configURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 首页

    private var homeSection: some View {
        Section("首页") {
            InfoRow(title: "首页内容", value: "剧集列表")
            Picker("展示方式", selection: $model.homeLayout) {
                ForEach(HomeLayout.allCases, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            Text("首页内容当前固定为剧集列表（分类 + 筛选 + 分页，两种展示方式共用同一份数据）；自定义首页区块不在本里程碑。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section("播放") {
            NavigationLink {
                SettingsPlayerView(model: model)
            } label: {
                InfoRow(title: "播放器", value: model.preferredEngine.displayName)
            }
            NavigationLink {
                SettingsPlaybackPageView(model: model)
            } label: {
                InfoRow(title: "播放页", value: "系统原生")
            }
            NavigationLink {
                SettingsDanmakuAPIView(model: model)
            } label: {
                InfoRow(title: "弹幕 API", value: parserSummary)
            }
        }
    }

    /// 解析器（弹幕 API）数量摘要。
    ///
    /// 刻意不用 `filter { ... }.count`（SwiftLint 的 contains_over_filter_count 偏好的写法是
    /// `contains`/等价循环），这里用 `for ... where` 数一次。
    private var parserSummary: String {
        let total = parsers.count
        guard total > 0 else {
            return "无"
        }
        var unavailableCount = 0
        for parser in parsers where !parser.availability.isAvailable {
            unavailableCount += 1
        }
        guard unavailableCount > 0 else {
            return "\(total) 个"
        }
        return "\(total) 个（\(unavailableCount) 个不可用）"
    }

    private var parsers: [ParserRule] {
        model.state.loadedSource?.config.parses ?? []
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section("数据") {
            NavigationLink {
                SettingsDownloadView()
            } label: {
                Text("下载管理")
            }
            NavigationLink {
                SettingsCacheView(model: model)
            } label: {
                Text("缓存管理")
            }
            NavigationLink {
                SettingsLogView(model: model)
            } label: {
                Text("日志管理")
            }
        }
    }

    // MARK: - iCloud 同步

    /// iCloud 同步：开关**置灰**并写明原因，同步 ID 是本机真实标识。
    private var syncSection: some View {
        Section("iCloud 同步") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步开关")
                    Text(model.localSyncIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("同步开关", isOn: .constant(false))
                    .labelsHidden()
                    .disabled(true)
            }
            Text("同步未落地：先做本地落库（M8，GRDB），再谈跨设备同步。开关先置灰，避免出现「已经同步了」的错觉。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
