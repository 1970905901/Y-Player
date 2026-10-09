import CatVodCore
import CatVodSource
import SwiftUI

/// 搜索页：搜索框 → 聚合搜索（按站点分组的海报墙）→ 详情。
///
/// 版式对齐用户给的参考图（M11 期）：搜索框在导航栏里、右侧圆形按钮打开
/// **「筛选站源」**（决定哪些站点参与搜索）；结果是**按站点分组**的墙 —— 左栏
/// 「全部 (命中站点数/搜索站点数) + 各站点命中数」，右栏竖幅海报网格（``AggregateSearchWall``）。
///
/// 与老版（一次搜一个站点 + 上拉翻页 + 站点面板）的区别是**有意的**：
/// 「全站聚合搜索」是 M5/M11 一直欠着的账（`docs/任务记录/M02P4-搜索页.md` 待做第 4 条），
/// 落点就是这里与详情页的 🔍 墙 —— 两面墙同一个组件、同一份站点范围（「筛选站源」那份开关）。
@MainActor
public struct SearchView: View {
    @ObservedObject var model: AppModel
    @State var keyword = ""
    /// 已经提交的关键词：空 = 还没搜（显示历史）。
    @State var submittedKeyword = ""
    /// 同一个关键词再提交一次也要重搜：给墙的 `revision`。
    @State var submitRevision = 0
    /// 「筛选站源」面板是否展开（搜索框右侧的圆形按钮）。
    @State var isFilterPresented = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        content
            .navigationTitle("搜索")
            .adaptiveInlineNavigationTitle()
            .adaptiveSearchBar(text: $keyword, prompt: "请输入影片名称") {
                SearchSourceFilterButton(isPresented: $isFilterPresented)
            }
            .onSubmit {
                submitSearch()
            }
            .sheet(isPresented: $isFilterPresented) {
                SearchSourceFilterView(model: model)
            }
    }

    // MARK: - 主体

    @ViewBuilder private var content: some View {
        if model.sites.isEmpty {
            placeholder(emptyHint)
        } else if submittedKeyword.isEmpty {
            historySection
        } else {
            AggregateSearchWall(model: model, keyword: submittedKeyword, revision: submitRevision)
        }
    }

    // MARK: - 搜索历史

    /// 还没搜索时的页面：标题「搜索历史」+ 清空按钮 + 历史胶囊（参考录屏的未搜索态）。
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("搜索历史")
                    .font(.headline)
                Spacer()
                if !model.searchHistory.isEmpty {
                    Button {
                        model.clearSearchHistory()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索历史")
                }
            }

            if model.searchHistory.isEmpty {
                Text("还没有搜索记录：点上面的搜索框输入片名，回车即可搜索。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // 自适应列宽的网格：不用手写换行逻辑（iOS 15 没有 `Layout` 协议，
                // 做不了「宽度撑开就换行」的流式布局）。
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 76), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(model.searchHistory, id: \.self) { term in
                        Button {
                            keyword = term
                            submitSearch()
                        } label: {
                            Text(term)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 空态

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.horizontal, 16)
    }

    /// 无可用站点时的说明（区分「接口加载失败」「没配置」「JS 源宿主状态」「没有可搜索站点」）。
    private var emptyHint: String {
        if let reason = model.state.failureReason {
            // 接口加载失败（含冷启动自动恢复失败）：直接说原因，别显示「请先加载配置」。
            return "接口加载失败：\(reason)"
        }
        if model.allSites.isEmpty {
            return "还没有可用站点：请先在「设置 → 源地址」里加载配置。"
        }
        if model.loadedKind == .javaScript {
            return model.hostStatus.summary
        }
        return "当前没有支持搜索的站点。"
    }
}
