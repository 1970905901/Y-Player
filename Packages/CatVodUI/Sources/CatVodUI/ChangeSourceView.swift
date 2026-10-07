import CatVodCore
import CatVodSource
import SwiftUI

/// 换源候选列表（详情页以 sheet 弹出）。
///
/// 由 ``ChangeSourceService`` 负责「查哪些站点、怎么排序、失败怎么兜」；
/// 本视图只做展示与选择，不自己拼请求。
@MainActor
struct ChangeSourceView: View {
    @ObservedObject var model: AppModel
    let title: String
    let currentSiteKey: String?
    let onPick: (ChangeSourceCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ChangeSourceCandidate] = []
    @State private var isLoading = true

    var body: some View {
        List {
            Section("换源") {
                Text("片名：\(title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在其它站点搜索…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if candidates.isEmpty {
                    Text("没有找到其它站点的同名内容（已跳过永久禁用与本平台不可用的站点）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !candidates.isEmpty {
                Section("候选（\(candidates.count)）") {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                        Button {
                            onPick(candidate)
                            dismiss()
                        } label: {
                            row(candidate)
                        }
                    }
                }
            }

            Section {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .adaptiveListStyle()
        .task { await search() }
    }

    private func row(_ candidate: ChangeSourceCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.item.vodName.isEmpty ? candidate.item.vodID : candidate.item.vodName)
                if candidate.isCurrent {
                    Text("当前站点")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(scoreText(candidate.score))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(candidate.site.name.isEmpty ? candidate.site.key : candidate.site.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !candidate.item.vodRemarks.isEmpty {
                Text(candidate.item.vodRemarks)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scoreText(_ score: Double) -> String {
        score >= 1 ? "完全匹配" : "匹配 \(Int(score * 100))%"
    }

    private func search() async {
        isLoading = true
        candidates = await model.makeChangeSourceService().candidates(
            title: title,
            sites: model.sites,
            currentSiteKey: currentSiteKey
        )
        isLoading = false
    }
}
