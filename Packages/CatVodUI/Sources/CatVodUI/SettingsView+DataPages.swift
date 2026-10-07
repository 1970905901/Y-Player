import SwiftUI

// 设置页的「数据」子页：下载管理 / 缓存管理 / 日志管理。
//
// 与「播放」子页同一套约定：能接真实数据的接真实数据，没有的写明缺什么与里程碑。

// MARK: - 下载管理

/// 下载管理：尚未落地，如实说明（不摆一个空任务列表出来骗人）。
@MainActor
struct SettingsDownloadView: View {
    var body: some View {
        List {
            Section("现状") {
                Label("尚未实现", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("离线下载需要「分片下载 + 任务队列 + 本地播放地址接管」，依赖 M6 的本地代理与后续的下载调度，尚未开始做，所以这里没有任何可管理的任务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("相关计划") {
                Text("M6：本地 `/proxy`（播放地址前缀语义与请求 header 透传）")
                Text("M8：本地落库（收藏 / 历史 / 播放进度）")
            }
        }
        .adaptiveListStyle()
        .navigationTitle("下载管理")
    }
}

// MARK: - 缓存管理

/// 缓存管理：接口（源配置）缓存的概览与清理。
///
/// 与「源地址 → 接口管理」里的「接口缓存」区块读的是同一份数据（``AppModel.sourceCacheSummary()``），
/// 这里把「清空」做成需要二次确认的破坏性操作。
@MainActor
struct SettingsCacheView: View {
    @ObservedObject var model: AppModel
    @State private var isConfirmingClear = false
    @State private var actionMessage = ""

    var body: some View {
        List {
            storageSection
            cacheSection
            Section("说明") {
                Text("缓存的是**接口配置本身**（JSON 文本、js2p 的 bundle 与 `.md5`），用于离线回退与跳过重复下载；清理后只是下次加载要重新下载，站点清单与播放设置不受影响。详情缓存是内存缓存（M02P5），不在这里管理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("缓存管理")
        .confirmationDialog("确定清空接口缓存？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空全部缓存", role: .destructive) {
                let removed = model.clearSourceCache()
                actionMessage = "已清理 \(removed) 个缓存文件"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("下次加载接口需要重新下载配置（JS 源约 6 MB）。站点与播放设置不受影响。")
        }
    }

    /// 本地存储（M08b）：落库路径与最近失败 —— 「存不上」必须能被看到，而不是静默丢数据。
    private var storageSection: some View {
        let failures = model.storageFailures
        return Section("本地存储") {
            InfoRow(title: "收藏 / 播放进度", value: model.storageSummary)
            if failures.isEmpty {
                Text("最近没有存储失败。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("最近失败 \(failures.count) 次：")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                ForEach(Array(failures.suffix(3).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cacheSection: some View {
        let summary = model.sourceCacheSummary()
        return Section("接口缓存") {
            if let summary, summary.entryCount > 0 {
                InfoRow(title: "条目", value: "\(summary.entryCount)")
                InfoRow(title: "占用", value: summary.formattedTotalSize)
                if let latest = summary.latestModifiedAt {
                    InfoRow(title: "最近更新", value: latest.formatted(date: .abbreviated, time: .shortened))
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
                isConfirmingClear = true
            } label: {
                Label("清空全部缓存", systemImage: "trash")
            }
            .disabled((summary?.entryCount ?? 0) == 0)

            if (summary?.orphanByteCount ?? 0) > 0 {
                Button {
                    let removed = model.pruneOrphanSourceCaches()
                    actionMessage = removed > 0
                        ? "已清理 \(removed) 个其他接口的缓存文件"
                        : "没有需要清理的残留"
                } label: {
                    Label("清理其他接口的缓存", systemImage: "rectangle.stack.badge.minus")
                }
            }

            if !actionMessage.isEmpty {
                Text(actionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 日志管理

/// 日志管理：目前唯一可查的运行日志是 js2p 宿主的输出。
///
/// 读得到就列出来，读不到就说清哪一类日志还没有 —— 不摆一个空列表假装有日志系统。
@MainActor
struct SettingsLogView: View {
    @ObservedObject var model: AppModel
    @State private var lines: [String] = []
    @State private var isLoading = false

    var body: some View {
        List {
            Section("宿主日志") {
                Text(model.hostStatus.summary)
                    .font(.footnote)
                    .foregroundStyle(model.hostStatus.isRunning ? Color.secondary : Color.orange)
                Button {
                    Task { await reload() }
                } label: {
                    Label("读取最近输出", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                if isLoading {
                    ProgressView()
                }
                if lines.isEmpty, !isLoading {
                    Text("点上面的按钮读取宿主最近的 stdout / stderr。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section("现状") {
                Text("可查的日志目前只有 js2p 宿主输出（Node 进程 / libnode）；网络请求、解析链与播放器的结构化日志尚未落地（属于 M5/M6 与后续的可观测性工作）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("日志管理")
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        lines = await model.hostDiagnostics()
    }
}
