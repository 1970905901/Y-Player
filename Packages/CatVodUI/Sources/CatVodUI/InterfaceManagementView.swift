import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 接口管理页：粘贴/导入配置地址 → 加载 → 展示站点清单与告警。
///
/// UI 约定（见 `docs/UI 规范.md`）：使用系统原生 `List` 与控件，
/// 通过 ``adaptiveListStyle()`` / ``AdaptiveNavigationContainer`` 获取各系统版本的原生外观，视图内不写版本分支。
public struct InterfaceManagementView: View {
    @ObservedObject private var model: AppModel
    @FocusState private var isURLFieldFocused: Bool

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
            sitesSection
            playbackSection
        }
        .adaptiveListStyle()
        .navigationTitle("接口管理")
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

    // MARK: - 站点清单

    private var sitesSection: some View {
        Section("站点") {
            if model.allSites.isEmpty {
                Text(model.loadedKind == .javaScript ? "JS 源待内嵌 Node 服务就绪后加载站点清单" : "暂无站点")
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
        let selection = model.playbackSelection()
        return Section("播放内核") {
            Picker("优先内核", selection: $model.preferredEngine) {
                ForEach(PlayerEngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName + (kind.isAvailable ? "" : "（当前不可用）")).tag(kind)
                }
            }
            InfoRow(title: "实际使用", value: selection.kind.displayName)
            if selection.didFallback {
                Text(selection.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.playbackNotice.isEmpty, !selection.didFallback {
                Text(model.playbackNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
        let kind = site.kind.map(String.init(describing:)) ?? "未知类型"
        let runtime = site.spiderRuntimeKind == .unsupported ? "" : "· \(site.spiderRuntimeKind.rawValue)"
        return "\(site.key) · \(kind)\(runtime)"
    }
}
