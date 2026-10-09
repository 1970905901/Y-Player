import CatVodSource
import SwiftUI

/// 手动匹配元信息（M11 片 5）：详情页「⋯」里那项打开的面板。
///
/// 为什么要有它：自动匹配是「按片名搜 TMDB、取第一条」，而站点给的片名常带杂质
/// （`[4K] 仙逆 第一季` / `仙逆 (2023)`）—— 搜不到、搜到别的，都真发生过。
/// 这一页让人自己指定「这一片到底是哪一条」。
///
/// 三条约定：
/// 1. **选中即生效**：点一条就落库并关面板 —— 一次只改一条记录，没有「批量改动要不要提交」的问题
///    （那是「筛选站源」要 ✓ 应用的原因，这里不需要）；
/// 2. **只影响这一片**：写的是 ``AppModel/setTMDBMatchKey(_:for:)``，键是片名；
/// 3. 搜不了就**说清为什么**（没配 key / 搜索失败 / 没搜到），不做「点了没反应的搜索框」。
@MainActor
struct TMDBMatchSheet: View {
    @ObservedObject var model: AppModel
    /// 这一片的片名（站点给的原文，就是手动匹配表里的键）。
    let title: String
    /// 选完 / 恢复自动：由调用方落库（面板自己不碰别的页面）。
    let onPick: (TMDBMatchKey?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var candidates: [TMDBMetadata] = []
    @State private var isSearching = false
    @State private var statusText = ""

    init(model: AppModel, title: String, onPick: @escaping (TMDBMatchKey?) -> Void) {
        self.model = model
        self.title = title
        self.onPick = onPick
        _query = State(initialValue: title)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                currentSection
                searchSection
                resultsSection
            }
            .adaptiveListStyle()
        }
    }

    // MARK: - 头部

    /// ✕（关掉，不改动）/ 标题。没有 ✓：选中一条就已经生效了。
    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("关闭")
            Spacer()
            Text("手动匹配元信息")
                .font(.headline)
            Spacer()
            // 与左侧 ✕ 同宽的占位：标题才是真的居中
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 当前

    @ViewBuilder
    private var currentSection: some View {
        let match = model.tmdbMatchKey(for: title)
        Section("当前") {
            HStack {
                Text("片名")
                Spacer()
                Text(title.isEmpty ? "（空）" : title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Text("元信息来源")
                Spacer()
                Text(match.map { "手动 · \($0.displayText)" } ?? "自动（按片名搜）")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if match != nil {
                Button("恢复自动匹配") {
                    onPick(nil)
                    dismiss()
                }
            }
        }
        .font(.footnote)
    }

    // MARK: - 搜索

    private var searchSection: some View {
        Section("搜索 TMDB") {
            HStack {
                TextField("片名 / 关键词", text: $query)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit {
                        Task { await search() }
                    }
                Button("搜索") {
                    Task { await search() }
                }
                .disabled(!canSearch)
            }
            if !model.isTMDBConfigured {
                Text("还没填 TMDB api key：设置 → 播放 → 播放页。填完回来再搜。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    private var canSearch: Bool {
        model.isTMDBConfigured
            && !isSearching
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func search() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            return
        }
        isSearching = true
        statusText = "正在搜…"
        defer { isSearching = false }
        do {
            let results = try await model.tmdbSearchCandidates(keyword)
            candidates = results
            statusText = results.isEmpty
                ? "没搜到「\(keyword)」—— 换个关键词（试试原名，或去掉季数 / 画质标签）。"
                : "找到 \(results.count) 条，点一条就用它。"
        } catch {
            candidates = []
            statusText = "搜索失败：\(userFacingMessage(error))"
        }
    }

    // MARK: - 候选

    @ViewBuilder
    private var resultsSection: some View {
        if !candidates.isEmpty {
            Section("候选") {
                ForEach(candidates, id: \.self) { item in
                    candidateRow(item)
                }
            }
        }
    }

    private func candidateRow(_ item: TMDBMetadata) -> some View {
        Button {
            onPick(TMDBMatchKey(kind: item.kind, id: item.id))
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: model.tmdbConfig.imageURL(item.posterPath)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? "（无标题）" : item.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text("\(item.kind == .movie ? "电影" : "剧集") · TMDB \(item.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !item.overview.isEmpty {
                        Text(item.overview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
