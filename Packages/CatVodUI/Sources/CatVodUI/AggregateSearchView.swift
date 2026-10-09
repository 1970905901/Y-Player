import CatVodCore
import CatVodSource
import SwiftUI

/// 聚合搜索海报墙**页面**（M11 片 5）：详情页图标行的 🔍 打开的页面。
///
/// 搜的就是**这部片的片名**，所以本页没有搜索框：要换关键词回搜索页，那是搜索页的活。
/// 墙面本体是 ``AggregateSearchWall``（与搜索页共用）；这里只管导航栏与「筛选站源」入口。
@MainActor
struct AggregateSearchView: View {
    @ObservedObject var model: AppModel
    /// 要搜的片名（详情页带过来的）。
    let keyword: String

    @State private var isFilterPresented = false

    var body: some View {
        AggregateSearchWall(model: model, keyword: keyword)
            .navigationTitle(keyword)
            .adaptiveInlineNavigationTitle()
            .adaptiveToolbar {
                EmptyView()
            } trailing: {
                SearchSourceFilterButton(isPresented: $isFilterPresented)
            }
            // 详情 → 海报墙这一路都不该出现底部 Tab 栏（登记机制见 Platform/AdaptiveTabBar.swift）。
            .immersiveTabBarPage()
            .sheet(isPresented: $isFilterPresented) {
                SearchSourceFilterView(model: model)
            }
    }
}
