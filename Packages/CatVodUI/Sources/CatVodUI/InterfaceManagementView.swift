import CatVodSource
import SwiftUI

/// 源管理页：粘贴/导入配置地址 → 加载 → 展示加载结果与告警。
///
/// 入口位置变了（对齐参考图的「设置 → 源地址」）：这个页面只负责「源地址本身」——
/// 接口地址 + 加载/强制刷新 + 状态 + 告警 + 站点清单 + 宿主状态。
///
/// 这里曾经还摆着「播放设置」与「接口缓存」两个区块，现已删除：同一个东西在两个地方
/// 各摆一份，用户没法判断哪份才算数 —— 播放设置在「设置 → 播放 → 播放器」，
/// 接口缓存在「设置 → 数据 → 缓存管理」。
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
    /// 宿主最近输出（点「查看宿主输出」后填充）。
    @State private var hostOutput: [String] = []

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            configSection
            subConfigSection
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
        }
        .adaptiveListStyle()
        .navigationTitle("源地址")
        .task {
            // 进页面探一次活：`hostStatus` 是旧结论，宿主可能已经崩了（M22P1）。
            await model.refreshHostHealth()
            // 站点 init 的失败清单（M16P10）：与宿主状态同处显示，省得去别处翻。
            await model.refreshSiteInitFailures()
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

    // MARK: - 多配置入口（多仓）

    /// 多仓（`urls`）里的子配置：一条一行，点了就**用它替换当前接口**并加载（M18P2）。
    ///
    /// 「点不动」的条目**置灰并写明原因**（相对地址但当前配置没有基准地址）——
    /// 与前几片同一条口径：不做「点了没反应」。
    @ViewBuilder
    private var subConfigSection: some View {
        let entries = model.configSubURLEntries
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    subConfigRow(entry)
                }
            } header: {
                Text("多配置入口")
            } footer: {
                Text("这份配置是多仓（`urls`）：点一条就**用它替换当前接口**并加载（上面的地址框也会换成它）。想回仓库那份，把仓库地址再填一次即可。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func subConfigRow(_ entry: ConfigSubURLEntry) -> some View {
        if let url = entry.url {
            Button {
                Task { await model.loadSubConfig(entry) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.raw)
                        .font(.footnote)
                    if url.absoluteString != entry.raw {
                        // 相对路径解析出来的实际地址：写出来，免得用户以为点的是别处。
                        Text(url.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(model.state.isLoading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.raw)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("这条解析不出地址（相对路径、而这份配置没有基准地址）：请把完整地址填进上面的输入框。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
                // 「我这份配置是新版吗」：摘要只说明是哪一份，时间和大小才是线索（M17P1）。
                if let size = CachedFileFacts.size(of: cached) {
                    InfoRow(title: "缓存大小", value: size)
                }
                if let modified = CachedFileFacts.modifiedAt(of: cached) {
                    InfoRow(title: "拉取时间", value: DiagnosticsReport.timestamp(modified))
                }
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
            // 探活（M22P1）：上面那行是**上次刷新**的结论，宿主可能已经崩了 ——
            // 这一行回答「现在这一刻还在不在」。
            InfoRow(title: "探活", value: model.hostHealth.text)
            if !model.siteInitFailures.isEmpty {
                // 站点 `POST /init` 失败（M16P10）：不阻断动作，但这是「某站点动作全失败」的
                // 第一诊断线索 —— 先报是哪个站点、失败在 init，再谈动作本身。
                Text("有站点初始化失败（不阻断动作，但可能是动作拿不到内容的原因）：")
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
                ForEach(Array(model.siteInitFailures.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Button("检测宿主") {
                Task { await model.refreshHostHealth() }
            }
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
