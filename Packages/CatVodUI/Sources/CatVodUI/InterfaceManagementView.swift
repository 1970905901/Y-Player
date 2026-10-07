import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 接口管理页：粘贴/导入配置地址 → 加载 → 展示站点清单与告警。
///
/// UI 约定（见 `docs/UI 规范.md`）：使用系统原生 `List` 与控件，
/// 通过 ``adaptiveListStyle()`` / ``AdaptiveNavigationContainer`` 获取各系统版本的原生外观，视图内不写版本分支。
///
/// 标注 `@MainActor`：本视图全程读写 `AppModel`（同样是 `@MainActor` 隔离），
/// 显式标注后在不同 Swift 语言模式（5 / 6）下都能正确编译。
@MainActor
public struct InterfaceManagementView: View {
    @ObservedObject private var model: AppModel
    @FocusState private var isURLFieldFocused: Bool
    @State private var isConfirmingCacheClear = false
    @State private var cacheActionMessage = ""
    /// 宿主最近输出（点「查看宿主输出」后填充）。
    @State private var hostOutput: [String] = []

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            configSection
            if case let .loaded(source) = model.state {
                summarySection(source)
            }
            if case let .failed(reason) = model.state {
                Section("加载失败") {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            if !model.warnings.isEmpty {
                warningsSection
            }
            if model.loadedKind == .javaScript {
                hostSection
            }
            sitesSection
            playbackSection
            cacheSection
        }
        .adaptiveListStyle()
        .navigationTitle("接口管理")
        .confirmationDialog("确定清空接口缓存？", isPresented: $isConfirmingCacheClear, titleVisibility: .visible) {
            Button("清空全部缓存", role: .destructive) {
                let removed = model.clearSourceCache()
                cacheActionMessage = "已清理 \(removed) 个缓存文件"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("下次加载接口需要重新下载配置（JS 源约 6 MB）。站点与播放设置不受影响。")
        }
    }

    // MARK: - 配置输入

    private var configSection: some View {
        Section("接口") {
            TextField("猫源 JSON 配置地址，或 js2p 的 index.js 地址", text: $model.configURL)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFieldFocused)
                .onSubmit { Task { await model.load() } }

            HStack {
                Button {
                    isURLFieldFocused = false
                    Task { await model.load() }
                } label: {
                    Label("加载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state.isLoading)

                Button {
                    Task { await model.load(forceRefresh: true) }
                } label: {
                    Label("强制刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.state.isLoading)

                if model.state.isLoading {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - 状态摘要

    private func summarySection(_ source: LoadedSource) -> some View {
        Section("状态") {
            InfoRow(title: "类型", value: source.kind == .javaScript ? "JS 源（js2p）" : "JSON 配置")
            if source.kind == .json {
                InfoRow(title: "站点数", value: "\(model.sites.count)")
                InfoRow(title: "首页站点", value: source.config.resolvedHomeSite?.name ?? "—")
                InfoRow(title: "默认解析器", value: source.config.resolvedParser?.name ?? "—")
            }
            if let digest = source.digest {
                InfoRow(title: "摘要", value: String(digest.prefix(12)) + "…")
            }
            if source.usedCache {
                Label("使用本地缓存配置", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
            }
            if source.usedOfflineFallback {
                Label("网络不可用，已回退缓存", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            }
            if let cached = source.cachedURL {
                InfoRow(title: "缓存文件", value: cached.lastPathComponent)
            }
        }
    }

    // MARK: - 告警

    private var warningsSection: some View {
        Section("告警") {
            ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Node 宿主（仅 JS 源）

    /// 宿主状态：端口、站点数、重启入口与诊断输出。
    ///
    /// 以前 JS 源只有一句「等 M1.6」的占位文案，用户无法区分
    /// 「平台不支持」「找不到 node」「宿主起来了但站点没加载出来」；这里把三者分开显示。
    private var hostSection: some View {
        Section("Node 宿主") {
            Text(model.hostStatus.summary)
                .font(.footnote)
                .foregroundStyle(model.hostStatus.isRunning ? Color.secondary : Color.orange)
            Button("重启宿主") {
                hostOutput = []
                Task {
                    await model.restartHost()
                    hostOutput = await model.hostDiagnostics()
                }
            }
            .disabled(model.hostStatus.isBusy)
            Button("查看宿主输出") {
                Task { hostOutput = await model.hostDiagnostics() }
            }
            ForEach(Array(hostOutput.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 站点清单

    private var sitesSection: some View {
        Section("站点") {
            if model.allSites.isEmpty {
                Text(model.loadedKind == .javaScript ? model.hostStatus.summary : "暂无站点")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.allSites) { site in
                SiteRow(site: site)
            }
        }
    }

    // MARK: - 播放内核

    private var playbackSection: some View {
        let resolution = model.resolvePlayback()
        return Section("播放设置") {
            Picker("播放内核", selection: $model.preferredEngine) {
                ForEach(PlayerEngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName + (kind.isAvailable ? "" : "（未接入）")).tag(kind)
                }
            }
            Picker("解码方式", selection: $model.decoderMode) {
                ForEach(DecoderMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            switch resolution {
            case let .ready(kind):
                InfoRow(title: "将使用", value: kind.displayName)
            case let .unavailable(kind, reason):
                InfoRow(title: "不可用", value: kind.displayName)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !model.playbackSettings.isDecoderModeEffective {
                Text("提示：系统播放器不支持强制硬解/软解，该选项对当前内核无效（切到 MPV / 自研 FFmpeg 内核后生效）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.playbackNotice.isEmpty {
                Text(model.playbackNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 接口缓存管理

    /// 缓存管理：**看得见**（条目 / 占用 / 最近更新）+ **清得掉**（全部 / 仅残留）。
    ///
    /// 策略（详见 `docs/任务记录/M02P7-接口缓存管理.md`）：
    /// - 容量上限 64 MB，超过后只淘汰**非当前接口**的最旧缓存；
    /// - 「清理其他接口」用于换源后回收残留（每个 JS 源 ≈ 6 MB）；
    /// - 清理缓存不影响站点清单与播放设置，只是下次加载要重新下载。
    private var cacheSection: some View {
        let summary = model.sourceCacheSummary()
        return Section("接口缓存") {
            if let summary, summary.entryCount > 0 {
                InfoRow(title: "条目", value: "\(summary.entryCount)")
                InfoRow(title: "占用", value: summary.formattedTotalSize)
                if let latest = summary.latestModifiedAt {
                    InfoRow(title: "最近更新", value: Self.dateText(latest))
                }
                if summary.currentEntryCount > 0 {
                    InfoRow(title: "当前接口", value: "\(summary.currentEntryCount) 个文件")
                }
                if summary.orphanByteCount > 0 {
                    InfoRow(title: "其他接口残留", value: summary.formattedOrphanSize)
                }
            } else {
                Text("暂无缓存：首次加载接口后会把配置存到本地（JS 源约 6 MB），用于离线回退与跳过重复下载。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                isConfirmingCacheClear = true
            } label: {
                Label("清空全部缓存", systemImage: "trash")
            }
            .disabled((summary?.entryCount ?? 0) == 0)

            if (summary?.orphanByteCount ?? 0) > 0 {
                Button {
                    let removed = model.pruneOrphanSourceCaches()
                    cacheActionMessage = removed > 0
                        ? "已清理 \(removed) 个其他接口的缓存文件"
                        : "没有需要清理的残留"
                } label: {
                    Label("清理其他接口的缓存", systemImage: "rectangle.stack.badge.minus")
                }
            }

            if !cacheActionMessage.isEmpty {
                Text(cacheActionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 时间显示：用系统本地化格式，不引入第三方格式化（iOS 15 起 `formatted(date:time:)` 可用）。
    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 键值信息行。
///
/// 不使用 `LabeledContent`：它是 iOS 16+/macOS 13+ 的 API，
/// 而本项目部署目标为 iOS 15（按 `docs/UI 规范.md`，低版本必须用该版本可用的原生实现）。
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 站点行：展示名称、类型与可用性原因。
struct SiteRow: View {
    let site: Site

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(site.name.isEmpty ? site.key : site.name)
                Spacer()
                if !site.availability.isAvailable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            SiteAvailabilityBadge(availability: site.availability)
        }
    }

    private var subtitle: String {
        let kind = site.kind.map { String(describing: $0) } ?? "未知类型"
        let runtime = site.spiderRuntimeKind == .unsupported ? "" : "· \(site.spiderRuntimeKind.rawValue)"
        return "\(site.key) · \(kind)\(runtime)"
    }
}
