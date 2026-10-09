import CatVodCore
import CatVodPlayer
import SwiftUI

/// 一个频道的节目单（时移回看的入口）。
///
/// 直接展示 ``AppModel/loadLiveGuide(for:)`` 拉回来的那几天（**昨天 / 今天 / 明天**，与上游
/// `LiveApi.getEpg` 的 `{-1, 0, 1}` 一致），所以不需要日期切换器 —— 上游也是把这几天的切片
/// 一起挂在频道上，界面自己选「今天」。
///
/// `lineIndex` 是「这个频道当前用第几条线路」（由直播页带进来，通常是上次看的那条）：
/// 时移地址要拼在**具体某个地址**后面，所以这个下标必须跟着走。
///
/// 每档的三种形态：
/// - `.live` 正在播：高亮，点它进直播；
/// - `.past` 已播：有时移地址就能点（走 `LiveCatchup` 拼出来的那一段），没有时移说明原因；
/// - `.future` 未开始：置灰，不给地址（上游同样只对已播档拼时移）。
@MainActor
struct LiveScheduleView: View {
    @ObservedObject var model: AppModel
    let channel: LiveChannel
    /// 时移地址按第几条线路拼（直播页带进来）。
    let lineIndex: Int

    var body: some View {
        List {
            if sections.isEmpty {
                // 没有节目单：把原因写出来（`liveEPGNotice` 里有仓库给的说明），
                // 别给一个空白的弹层让人猜。
                Section {
                    Text(model.liveEPGNotice.isEmpty ? "这个频道暂时没有节目单。" : model.liveEPGNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(sections, id: \.id) { schedule in
                Section(schedule.date) {
                    ForEach(rows(for: schedule)) { row in
                        programRow(row)
                    }
                }
            }
            if channel.urls.count > 1 {
                Section {
                    Text("时移地址按「\(LiveListLayout.lineTitle(channel: channel, lineIndex: lineIndex))」拼接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle(channel.name)
        .task { await model.loadLiveGuide(for: channel) }
    }

    // MARK: - 数据

    /// 这个频道已拿到的切片（按日期升序）。
    private var sections: [EPGSchedule] {
        let key = channel.epgID
        let schedules = model.liveGuide(for: channel)?.schedules ?? []
        return schedules.filter { $0.key == key }.sorted { $0.date < $1.date }
    }

    private func rows(for schedule: EPGSchedule) -> [LiveProgramRow] {
        LiveListLayout.programRows(channel: channel, schedule: schedule, lineIndex: lineIndex)
    }

    // MARK: - 行

    @ViewBuilder private func programRow(_ row: LiveProgramRow) -> some View {
        if let url = row.catchupURL {
            // 已播 + 有地址：交给同一个播放页，资源走本机代理注入 header。
            NavigationLink {
                PlaybackView(
                    resource: resource(url: url),
                    title: "\(channel.name) · \(row.title)",
                    settings: model.playbackSettings,
                    onPlaybackStats: { model.notePlaybackStats($0) },
                    onStart: { model.resetAdSkip() }
                )
            } label: {
                label(row)
            }
        } else if row.state == .live {
            NavigationLink {
                PlaybackView(
                    resource: resource(url: channel.playbackURL(index: lineIndex)),
                    title: channel.name,
                    settings: model.playbackSettings,
                    onPlaybackStats: { model.notePlaybackStats($0) },
                    onStart: { model.resetAdSkip() }
                )
            } label: {
                label(row)
            }
        } else {
            label(row)
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ row: LiveProgramRow) -> some View {
        HStack(spacing: 8) {
            Text(row.timeRange)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(row.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(trailingText(row))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 右侧说明：正在播 / 可回看 / 未开始 / 没有时移 —— 点不动的原因要写出来。
    private func trailingText(_ row: LiveProgramRow) -> String {
        switch row.state {
        case .live:
            return "正在播"
        case .future:
            return "未开始"
        case .past:
            return row.catchupURL == nil ? "无时移" : "可回看"
        }
    }

    private func resource(url: String) -> MediaResource {
        model.playbackResource(MediaResource(
            url: url,
            headers: channel.requestHeaders(fallback: model.liveSource?.headers() ?? [:])
        ))
    }
}
