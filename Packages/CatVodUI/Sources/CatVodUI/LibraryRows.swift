import CatVodStore
import SwiftUI

// 「追剧」页的行视图：字段与顺序对齐参考图（海报 + 片名 + 站源/线路/剧集/观看至/总时长）。

/// 多选态的勾选标记（nil 表示不在多选态 —— 不占位、不显示）。
///
/// 用系统图标画「未选 / 已选」，不自绘控件：两端（iOS/macOS）观感一致，
/// 也避免依赖 iOS 专有的 `EditMode`（见 ``LibraryView`` 里的说明）。
struct SelectionMark: View {
    let isSelected: Bool?

    var body: some View {
        if let isSelected {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.top, 2)
        }
    }
}

/// 列表海报缩略图（与首页 ``VodRow`` 同尺寸，保持两处观感一致）。
struct PosterThumbnail: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.secondary.opacity(0.15)
        }
        .frame(width: 60, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))
    }
}

/// 「播放历史」行。
struct HistoryRow: View {
    let record: PlaybackProgress
    /// 站点展示名（记录里可能为空，由列表按当前接口回退后传入）。
    let siteName: String
    /// 多选态下的勾选状态；nil 表示当前不在多选态（不画圆点）。
    let isSelected: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SelectionMark(isSelected: isSelected)
            PosterThumbnail(url: record.picture)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                detailLine("站源", siteName)
                detailLine("线路", record.lineName)
                detailLine("剧集", record.episodeName)
                detailLine("观看至", PlaybackView.timeText(record.position))
                if record.duration > 0 {
                    detailLine("总时长", PlaybackView.timeText(record.duration))
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func detailLine(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            Text("\(title)：\(value)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 「收藏记录」行。
struct FavoriteRow: View {
    let favorite: Favorite
    /// 站点展示名（记录里可能为空，由列表按当前接口回退后传入）。
    let siteName: String
    /// 该站点是否仍在当前接口里（false 时无法进详情，行内说明原因）。
    let isOpenable: Bool
    /// 多选态下的勾选状态；nil 表示当前不在多选态（不画圆点）。
    let isSelected: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SelectionMark(isSelected: isSelected)
            PosterThumbnail(url: favorite.picture)
            VStack(alignment: .leading, spacing: 4) {
                Text(favorite.vodName.isEmpty ? favorite.key.vodID : favorite.vodName)
                detailLine("站源", siteName)
                detailLine("线路", favorite.lineName)
                detailLine("剧集", favorite.episodeName)
                detailLine("收藏于", favorite.addedAt.formatted(date: .abbreviated, time: .shortened))
                if !isOpenable {
                    Text("该站点已不在当前接口里，进不了详情；可先在「设置 → 源地址」重新加载接口。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func detailLine(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            Text("\(title)：\(value)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
