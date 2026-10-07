import CatVodCore
import CatVodSource
import SwiftUI

// 首页的数据加载逻辑（与视图分离，便于单测与复用）。

extension HomeView {
    /// 筛选器绑定：未选择时使用上游给的初始值。
    func binding(for filter: VodFilter) -> Binding<String> {
        Binding(
            get: { extend[filter.key] ?? filter.initialValue },
            set: { extend[filter.key] = $0 }
        )
    }

    /// 加载首页（分类 + 首屏内容）。
    func loadHome(force: Bool = false) async {
        guard let site = selectedSite else {
            return
        }
        if !force, !result.categories.isEmpty {
            return
        }
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        do {
            let home = try await model.makeSiteClient().home(site: site)
            // 补图是 best-effort：失败或站点不支持时原样返回，不打断首页。
            result = await model.makePictureFiller().fill(site: site, result: home)
            let firstCategoryID = home.categories.first?.typeID ?? ""
            if selectedCategoryID.isEmpty {
                selectedCategoryID = firstCategoryID
            }
            let targetCategory = selectedCategoryID.isEmpty ? firstCategoryID : selectedCategoryID
            if !targetCategory.isEmpty {
                await loadCategory(categoryID: targetCategory, site: site)
            }
        } catch {
            errorText = describe(error)
        }
    }

    /// 加载某个分类的某页。
    func loadCategory(categoryID: String? = nil, site: Site? = nil) async {
        guard let targetSite = site ?? selectedSite else {
            return
        }
        let targetCategory = categoryID ?? selectedCategoryID
        guard !targetCategory.isEmpty else {
            return
        }
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        do {
            let category = try await model.makeSiteClient().category(
                site: targetSite,
                categoryID: targetCategory,
                page: page,
                extend: extend
            )
            let filled = await model.makePictureFiller().fill(site: targetSite, result: category)
            if filled.hasList || filled.hasCategories || filled.code == 0 {
                result = filled
            }
            if selectedCategoryID != targetCategory {
                selectedCategoryID = targetCategory
            }
        } catch {
            errorText = describe(error)
        }
    }

    func describe(_ error: Error) -> String {
        userFacingMessage(error)
    }
}

/// 内容行：海报 + 标题 + 备注。
struct VodRow: View {
    let item: VodItem

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: item.vodPic)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 60, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.vodName.isEmpty ? item.vodID : item.vodName)
                if !item.vodRemarks.isEmpty {
                    Text(item.vodRemarks)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.isFolder {
                    Text("文件夹")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
