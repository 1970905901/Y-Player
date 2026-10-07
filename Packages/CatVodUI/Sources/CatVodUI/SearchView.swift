import CatVodCore
import CatVodSource
import SwiftUI

/// 搜索页：选站点 → 关键词 → 结果 → 详情。
///
/// 范围（M2）：只走 CMS 通道（`type 0/1/2/4`）。
/// `type=3` 的 JS/CatSpider 站点搜索依赖 M1.6 的内嵌 Node 服务，这里明确提示而不是静默返回空结果。
/// 数据加载逻辑见 `SearchView+Data.swift`。
@MainActor
public struct SearchView: View {
    @ObservedObject var model: AppModel
    @State var selectedSiteKey = ""
    @State var keyword = ""
    @State var submittedKeyword = ""
    @State var result = SpiderResult()
    @State var page = 1
    @State var isLoading = false
    @State var errorText = ""

    public init(model: AppModel) {
        self.model = model
    }

    /// 走 CMS 通道、可直接搜索的站点。
    var cmsSites: [Site] {
        model.sites.filter { $0.kind != .spider }
    }

    /// 需要内嵌 Node 服务才能搜索的站点（仅用于提示）。
    var spiderSites: [Site] {
        model.sites.filter { $0.kind == .spider }
    }

    var selectedSite: Site? {
        cmsSites.first { $0.key == selectedSiteKey } ?? cmsSites.first
    }

    public var body: some View {
        List {
            if cmsSites.isEmpty {
                Section("搜索") {
                    Text(emptyHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                siteSection
                resultsSection
                if !result.list.isEmpty {
                    pagingSection
                }
            }
            if !errorText.isEmpty {
                Section("错误") {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle("搜索")
        .adaptiveSearchable(text: $keyword, prompt: "输入片名关键词")
        .onSubmit(of: .search) {
            Task { await runSearch() }
        }
        .task {
            if selectedSiteKey.isEmpty {
                selectedSiteKey = cmsSites.first?.key ?? ""
            }
        }
        .onChange(of: selectedSiteKey) { _ in
            // 换站点后清空上次结果，避免把别的站点的结果显示成本站点的结果。
            result = SpiderResult()
            page = 1
            submittedKeyword = ""
        }
    }

    // MARK: - 区块

    private var siteSection: some View {
        Section("站点") {
            Picker("当前站点", selection: $selectedSiteKey) {
                ForEach(cmsSites) { site in
                    Text(site.name.isEmpty ? site.key : site.name).tag(site.key)
                }
            }
        }
    }

    private var resultsSection: some View {
        Section("结果") {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("搜索中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if submittedKeyword.isEmpty {
                Text("输入关键词后回车搜索。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if result.list.isEmpty {
                Text("没有找到与「\(submittedKeyword)」相关的内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.list) { item in
                NavigationLink {
                    VodDetailView(model: model, site: selectedSite, vodID: item.vodID)
                } label: {
                    VodRow(item: item)
                }
            }
        }
    }

    private var pagingSection: some View {
        Section {
            HStack {
                Button("上一页") {
                    Task { await runSearch(targetPage: page - 1) }
                }
                .disabled(page <= 1 || isLoading)

                Spacer()
                Text(pageText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()

                Button("下一页") {
                    Task { await runSearch(targetPage: page + 1) }
                }
                .disabled(isLoading || (result.pagecount > 0 && page >= result.pagecount))
            }
        }
    }

    private var pageText: String {
        result.pagecount > 0 ? "第 \(page) / \(result.pagecount) 页" : "第 \(page) 页"
    }

    /// 无可用站点时的说明（区分「没配置」「只有 JS 源」「没有 CMS 站点」）。
    private var emptyHint: String {
        if model.allSites.isEmpty {
            return "还没有可用站点：请先在「接口管理」里加载配置。"
        }
        if model.loadedKind == .javaScript {
            return "当前是 JS 源（js2p）：站点清单需等内嵌 Node 服务就绪（M1.6 落地）。"
        }
        if !spiderSites.isEmpty {
            return "当前配置里只有 JS/CatSpider 站点（type=3），搜索依赖内嵌 Node 服务（M1.6）。"
        }
        return "当前配置里没有支持搜索的 CMS 站点（type 0/1/2/4）。"
    }
}
