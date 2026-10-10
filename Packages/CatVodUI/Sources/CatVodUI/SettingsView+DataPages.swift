import CatVodCore
import CatVodPlayer
import SwiftUI
import UniformTypeIdentifiers

// 设置页的「数据」子页：下载管理 / 缓存管理 / 日志管理。
//
// 与「播放」子页同一套约定：能接真实数据的接真实数据，没有的写明缺什么与里程碑。

// MARK: - 下载管理

/// 下载管理：存储空间条 + 下载内容区。
///
/// 两块结构对齐参考图：上面是「进度条 + 图例（总空间 / 已用 / 下载）」，
/// 下面是内容区（参考图是空态卡片「暂无下载内容」）。
///
/// 三个数字都来自真实查询（``StorageSpace``：卷容量 + 下载目录实际占用）；
/// 离线下载从 M10 起已可用：这里的列表就是真任务、空态就是真没有（不摆假数据）。
@MainActor
struct SettingsDownloadView: View {
    @ObservedObject var model: AppModel

    /// 空间快照：进页面查一次（查询要遍历下载目录，不适合每次重绘都算）。
    @State private var snapshot = StorageSpace.Snapshot()

    var body: some View {
        List {
            Section {
                StorageBar(snapshot: snapshot)
            }
            Section {
                if model.downloadTasks.isEmpty {
                    emptyState
                } else {
                    ForEach(model.downloadTasks) { task in
                        taskRow(task)
                    }
                    Button("清空下载（连文件一起删）", role: .destructive) {
                        Task {
                            await model.clearDownloads()
                            refresh()
                        }
                    }
                }
            } header: {
                HStack {
                    Text("下载内容")
                    Spacer()
                    if model.isDownloading {
                        Text("正在下载…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("下载在**应用处于前台时自动推进**（入队即开始；App 不在前台也继续下的「后台下载」还没做）：列表里的进度、暂停与删除都作用在真实任务上，文件落在应用数据目录的 `Downloads/` 下。")
            }
        }
        .adaptiveListStyle()
        .navigationTitle("下载管理")
        .task {
            refresh()
            await model.synchronizeDownloads()
            // 驱动挂在 model 上（入队即启动、回到前台再启动）：这一页只负责把它叫醒 + 刷新界面，
            // 不再独占「谁来推进队列」这件事。
            model.startDownloadDriverIfNeeded()
            refresh()
        }
    }

    /// 一条任务：标题 · 集名 + 状态 + 进度 + 操作。
    ///
    /// 进度有两种形态：知道总量就画确定进度条，不知道就画不确定态 —— 这正是 M10a 把
    /// `progress` 做成可选值的原因（`0` 会让人以为「卡在开头」）。
    private func taskRow(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title(of: task))
                    .lineLimit(1)
                Spacer()
                Text(statusText(task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if task.status == .running {
                if let progress = task.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            HStack(spacing: 16) {
                if task.status == .finished, let file = model.localDownloadedFile(forRemoteURL: task.url) {
                    // 已下好的本地文件直接交给播放页：地址是 `file://`、不需要 header，
                    // 也不带弹幕/字幕（那是从站点结果来的，本地文件没有对应的搜索上下文）。
                    NavigationLink {
                        PlaybackView(
                            resource: MediaResource(url: file.absoluteString),
                            title: title(of: task),
                            settings: model.playbackSettings,
                            onPlaybackStats: { model.notePlaybackStats($0) }
                        )
                    } label: {
                        Text("播放")
                    }
                }
                if task.status != .finished {
                    Button(primaryActionTitle(task)) {
                        Task {
                            await toggle(task)
                            model.startDownloadDriverIfNeeded()
                            refresh()
                        }
                    }
                }
                Button("删除", role: .destructive) {
                    Task {
                        await model.removeDownload(id: task.id)
                        refresh()
                    }
                }
            }
            .font(.caption)
            if !task.failureReason.isEmpty {
                Text(task.failureReason)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func title(of task: DownloadTask) -> String {
        task.episode.isEmpty ? task.title : "\(task.title) · \(task.episode)"
    }

    /// 状态文案：说得清「现在到底在干什么」。
    private func statusText(_ task: DownloadTask) -> String {
        switch task.status {
        case .waiting:
            "排队中"
        case .running:
            "下载中"
        case .paused:
            "已暂停"
        case .finished:
            "已完成"
        case .failed:
            "失败"
        }
    }

    private func primaryActionTitle(_ task: DownloadTask) -> String {
        switch task.status {
        case .waiting, .running:
            "暂停"
        case .paused, .failed:
            "继续"
        case .finished:
            ""
        }
    }

    private func toggle(_ task: DownloadTask) async {
        switch task.status {
        case .waiting, .running:
            await model.pauseDownload(id: task.id)
        case .paused, .failed:
            await model.resumeDownload(id: task.id)
        case .finished:
            break
        }
    }

    /// 空态卡片：图标 + 标题 + 原因（对齐参考图的居中块）。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("暂无下载内容")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("在播放页点「下载本集」、或在详情页点「整部下载」就会出现在这里；下好的集在播放时会自动走本地文件（本地地址接管，M10g）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func refresh() {
        snapshot = StorageSpace.snapshot(downloadDirectory: model.downloadDirectory)
    }
}

/// 存储空间条：灰底 + 蓝色「已用」段 + 绿色「下载」段，下面一行图例。
///
/// 自绘而不是 `ProgressView`：参考图里同一条上有两种颜色（已用 / 下载），
/// 系统进度视图只支持单色，用 `GeometryReader` + `Capsule` 才能如实还原。
struct StorageBar: View {
    let snapshot: StorageSpace.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * snapshot.usedRatio)
                    Capsule()
                        .fill(Color.green)
                        .frame(width: proxy.size.width * snapshot.downloadRatio)
                }
            }
            .frame(height: 8)

            HStack(spacing: 10) {
                Label("总空间 \(snapshot.formattedTotal)", systemImage: "internaldrive")
                swatch(color: .accentColor, text: "已用 \(snapshot.formattedUsed)")
                swatch(color: .green, text: "下载 \(snapshot.formattedDownload)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// 图例小方块（参考图里是彩色小方块 + 文字）。
    private func swatch(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }
}

// MARK: - 缓存管理

/// 缓存管理：接口（源配置）缓存的概览与清理。
///
/// 与「源地址 → 接口管理」里的「接口缓存」区块读的是同一份数据（``AppModel.sourceCacheSummary()``），
/// 这里把「清空」做成需要二次确认的破坏性操作。
@MainActor
struct SettingsCacheView: View {
    /// 三个「清空」共用一次二次确认：点哪一行就把待确认目标换成哪一行。
    private enum ClearTarget {
        case source
        case home
        case all

        var confirmTitle: String {
            switch self {
            case .source: "确定清空源缓存？"
            case .home: "确定清空首页缓存？"
            case .all: "确定清空全部缓存？"
            }
        }

        var confirmMessage: String {
            switch self {
            case .source:
                "下次加载接口要重新下载配置（JS 源约 6 MB）。站点清单与播放设置不受影响。"
            case .home:
                "首页与分类列表要重新请求一次。收藏、播放进度与站点配置都不受影响。"
            case .all:
                "接口配置与首页数据都要重新拉取一次。收藏、播放进度与站点配置不受影响。"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var isConfirmingClear = false
    @State private var clearTarget: ClearTarget = .source
    @State private var actionMessage = ""

    var body: some View {
        List {
            cacheSection
            storageSection
            Section("说明") {
                Text(explanationText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("下载内容与本地库（收藏 / 播放进度）不算缓存：前者见「下载管理」，后者见下方「本地存储」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // 换接口后旧 bundle 会永久残留（每个 ≈ 6 MB）：参考图没有这一项，
            // 但它是 M02P7 就有的真实能力，丢掉会让用户没地方回收这块空间 —— 只在真的有残留时出现。
            if let orphanSize = model.sourceCacheSummary()?.formattedOrphanSize,
               (model.sourceCacheSummary()?.orphanByteCount ?? 0) > 0
            {
                Section("回收") {
                    Button("清理其他接口残留（\(orphanSize)）") {
                        let removed = model.pruneOrphanSourceCaches()
                        actionMessage = "已清理 \(removed) 个其他接口的缓存文件"
                    }
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle("缓存管理")
        .confirmationDialog(clearTarget.confirmTitle, isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { performClear() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(clearTarget.confirmMessage)
        }
    }

    /// 说明区文案：把「两个时间怎么生效」「当前各占多少」写清楚，不必靠猜。
    private var explanationText: String {
        let sourcePart = model.sourceCacheSummary()
            .map { "源缓存 \($0.entryCount) 个文件、\($0.formattedTotalSize)" } ?? "源缓存目录不可读"
        let homePart = model.homeCacheSummary()
            .map { "首页缓存 \($0.entryCount) 个文件、\($0.formattedSize)" } ?? "首页缓存目录不可读"
        return "源缓存时间：接口配置在有效期内**直接读本地、不联网**，过期或手动「刷新接口」才重新下载"
            + "（js2p 接口例外：每次加载只拉几十字节的 `.md5` 摘要，变了才重下 bundle —— 上游给的就是增量更新）；"
            + "首页缓存时间：首页与分类列表在有效期内直接读本地缓存。"
            + "当前 \(sourcePart)；\(homePart)。详情缓存仍是内存缓存（M02P5），不在这里管理。"
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

    /// 「缓存」组：结构与顺序**逐行对齐参考图** ——
    /// 源缓存时间 / 源缓存数据 / 首页缓存时间 / 首页缓存数据 / 全部缓存 (大小)。
    ///
    /// 两个「时间」是真生效的偏好（读取侧见 `SourceRepository+FreshCache.swift` 与
    /// `HomeView+Data.swift`），三个「清空」按参考图放在行右，二次确认后执行。
    private var cacheSection: some View {
        Section("缓存") {
            Picker("源缓存时间", selection: $model.sourceCacheLifetime) {
                ForEach(CacheLifetime.allCases, id: \.self) { lifetime in
                    Text(lifetime.displayName).tag(lifetime)
                }
            }
            .pickerStyle(.menu)

            clearRow(title: "源缓存数据", target: .source, isEnabled: model.sourceCacheByteCount > 0)

            Picker("首页缓存时间", selection: $model.homeCacheLifetime) {
                ForEach(CacheLifetime.allCases, id: \.self) { lifetime in
                    Text(lifetime.displayName).tag(lifetime)
                }
            }
            .pickerStyle(.menu)

            clearRow(title: "首页缓存数据", target: .home, isEnabled: model.homeCacheByteCount > 0)

            clearRow(
                title: "全部缓存 (\(model.formattedTotalCacheSize))",
                target: .all,
                isEnabled: model.totalCacheByteCount > 0
            )

            if !actionMessage.isEmpty {
                Text(actionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 参考图的「清空」：标题在左、蓝色「清空」在右。
    ///
    /// 用 `.buttonStyle(.borderless)` 让点击热区只落在「清空」两个字上（默认整行都会变成按钮）；
    /// 破坏性由二次确认承担，所以不把整行染红，保持与参考图一致的系统蓝。
    private func clearRow(title: String, target: ClearTarget, isEnabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("清空") {
                clearTarget = target
                isConfirmingClear = true
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
        }
    }

    /// 执行二次确认后的清理。
    private func performClear() {
        switch clearTarget {
        case .source:
            actionMessage = "已清理源缓存 \(model.clearSourceCache()) 个文件"
        case .home:
            actionMessage = "已清理首页缓存 \(model.clearHomeCache()) 个文件"
        case .all:
            actionMessage = "已清理全部缓存 \(model.clearAllCaches()) 个条目"
        }
    }
}

// MARK: - 日志管理

/// 日志管理：日志开关 + 引擎日志导出。
///
/// 结构对齐参考图的两行：`日志开关`（Toggle）与 `引擎日志 (大小)` → `导出`。
///
/// - 开关是**真实生效**的偏好：它决定宿主（js2p / libnode）的输出是否**落盘**
///   （关闭时只在内存里保留最近若干行，不占磁盘）；
/// - 「导出」优先导出落盘日志，没有落盘时退回内存里的最近输出，走系统原生的
///   `fileExporter`（iOS 14+ / macOS 11+），不自绘文件对话框。
@MainActor
struct SettingsLogView: View {
    @ObservedObject var model: AppModel
    @State private var lines: [String] = []
    @State private var logPath: URL?
    @State private var logByteCount: Int64 = 0
    @State private var isLoading = false
    @State private var isExporting = false
    @State private var exportDocument = EngineLogDocument(text: "")
    /// 复制诊断信息之后的一行反馈（成功/失败都要说，不做点了没反应）。
    @State private var diagnosticsNotice = ""

    var body: some View {
        List {
            Section {
                Toggle("日志开关", isOn: $model.isEngineLogEnabled)
                HStack {
                    Text("引擎日志 (\(StorageSpace.format(logByteCount)))")
                    Spacer()
                    Button("导出") {
                        Task { await prepareExport() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading || (lines.isEmpty && logByteCount == 0))
                }
                Text(model.hostStatus.summary)
                    .font(.footnote)
                    .foregroundStyle(model.hostStatus.isRunning ? Color.secondary : Color.orange)
            }
            Section {
                Button {
                    Task { await copyDiagnostics() }
                } label: {
                    Label("复制诊断信息", systemImage: "doc.on.doc")
                }
                if !diagnosticsNotice.isEmpty {
                    Text(diagnosticsNotice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("诊断")
            } footer: {
                Text("把「环境 / 接口与摘要 / 播放设置 / 内核可用性 / 下载 / 宿主 / 失败记录」拼成一段文本复制到剪贴板 —— 反馈问题时贴这段比截图省事。接口地址只留主机与路径，查询串整体抹掉。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("说明") {
                Text("日志开关控制宿主输出是否落盘：开启后运行日志会写进日志文件，重启应用后仍在；关闭时只在内存里保留最近若干行，进程退出即消失（致命错误无论如何都会落盘，否则崩溃就没有现场）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("可查的日志目前只有 js2p 宿主（Node 进程 / libnode）的输出；网络请求与解析链的结构化日志尚未落地 —— 失败会在「诊断」里汇总。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !lines.isEmpty {
                Section("最近输出") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle("日志管理")
        .task { await reload() }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "YPlayer-引擎日志"
        ) { _ in }
    }

    /// 复制诊断信息（M17P1）：报告是纯文本，直接进剪贴板，粘到聊天窗口或记事本都行。
    private func copyDiagnostics() async {
        let report = await model.diagnosticsReport()
        PlatformShims.copyToClipboard(report.text)
        let lineCount = report.text.split(separator: "\n").count
        diagnosticsNotice = "已复制 \(lineCount) 行到剪贴板。"
    }

    /// 读一次日志现状：内存输出 + 落盘文件（路径与大小）。
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        lines = await model.hostDiagnostics(limit: 200)
        logPath = await model.hostLogPath()
        let onDisk = Self.byteCount(of: logPath)
        // 开关关闭时宿主不落盘，此时「引擎日志」就是内存里这份输出的体量。
        logByteCount = model.isEngineLogEnabled ? onDisk : Int64(lines.joined(separator: "\n").utf8.count)
    }

    /// 导出：先刷新一次，再把内容交给系统文件导出器。
    private func prepareExport() async {
        await reload()
        let content = exportText()
        guard !content.isEmpty else {
            return
        }
        exportDocument = EngineLogDocument(text: content)
        isExporting = true
    }

    private func exportText() -> String {
        if let logPath, let text = try? String(contentsOf: logPath, encoding: .utf8), !text.isEmpty {
            return text
        }
        return lines.joined(separator: "\n")
    }

    private static func byteCount(of url: URL?) -> Int64 {
        guard let url,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }
}

/// 导出用的纯文本文档（引擎日志）。
///
/// 用 `FileDocument` 而不是把日志写到共享目录再让用户自己找：`fileExporter` 是原生导出通道，
/// 两端（iOS / macOS）都会给出系统自己的「存储到…」界面。
struct EngineLogDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText]
    }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
