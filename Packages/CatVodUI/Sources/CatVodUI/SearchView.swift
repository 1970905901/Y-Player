import CatVodCore
import CatVodSource
import SwiftUI

/// 搜索页：选站点 → 关键词 → 结果 → 详情。
///
/// 站点来源：CMS 与 CatSpider HTTP（js2p 宿主）都能搜，由 `AppModel.makeSiteClient()` 分发；
/// JS 源的站点清单来自内嵌 Node 宿主（macOS 可用，iOS 待 libnode）。
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

    /// 可浏览的站点。
    ///
    /// 同时包含 CMS（`type 0/1/2/4`）与 CatSpider HTTP（`type 3`，js2p 宿主站点）：
    /// 两者都由 `AppModel.makeSiteClient()` 按类型分发，界面不再需要自己区分。
    var browsableSites: [Site] {
        model.sites
    }

    var selectedSite: Site? {
        browsableSites.first { $0.key == selectedSiteKey } ?? browsableSites.first
    }

    public var body: some View {
        List {
            if browsableSites.isEmpty {
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
                selectedSiteKey = browsableSites.first?.key ?? ""
            }
        }
        .onChange(of: selectedSiteKey) { _ in
            // 换站点后清空上次结果，避免把别的站点的结果显示成本站点的结果。
            result = SpiderResult()
            page = 1
            submittedKeyword = ""
        }
        .onChange(of: model.siteCatalogRevision) { _ in
            // 接口换了（搜索页常驻在首页 Tab 的导航栈里，`.task` 不会重跑）：旧站点与旧结果全部作废，
            // 否则搜索会继续对着上一个接口的站点发请求。
            result = SpiderResult()
            page = 1
            submittedKeyword = ""
            if !browsableSites.contains(where: { $0.key == selectedSiteKey }) {
                selectedSiteKey = browsableSites.first?.key ?? ""
            }
        }
    }

    // MARK: - 区块

    private var siteSection: some View {
        Section("站点") {
            Picker("当前站点", selection: $selectedSiteKey) {
                ForEach(browsableSites) { site in
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

    /// 无可用站点时的说明（区分「接口加载失败」「没配置」「JS 源宿主状态」「没有可搜索站点」）。
    private var emptyHint: String {
        if let reason = model.state.failureReason {
            // 接口加载失败（含冷启动自动恢复失败）：直接说原因，别显示「请先加载配置」。
            return "接口加载失败：\(reason)"
        }
        if model.allSites.isEmpty {
            return "还没有可用站点：请先在「接口管理」里加载配置。"
        }
        if model.loadedKind == .javaScript {
            return model.hostStatus.summary
        }
        return "当前没有支持搜索的站点。"
    }
}
