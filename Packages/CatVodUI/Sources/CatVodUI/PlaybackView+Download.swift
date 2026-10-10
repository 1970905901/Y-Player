import CatVodCore
import CatVodPlayer
import Foundation
import SwiftUI

/// 播放页的**离线下载入口**（M10f）：把当前这一集交给上层的下载队列。
///
/// 播放页不认识 `AppModel`：队列只有上层知道，这里只负责把「这一集是谁」拼清楚再交上去。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数顶到了 SwiftLint 的 `file_length` error（800）——
/// 拆文件不如拆职责：主文件留播放本体，这块独立成文件（与 `VodDetailView+Emby` 同一套做法）。
/// 跨文件的成员不能带 `private`：主文件里被这里用到的 `@State` 因此改成了默认（internal）。
extension PlaybackView {
    // MARK: - 离线下载（M10f）

    /// 把这一集加进下载队列。
    ///
    /// 三处取值的理由：
    /// - **站点 key** 从 `progressContext` 取 —— 播放页本来就不认识站点配置，
    ///   进度上下文是它手上唯一「这一集是谁」的线索；
    /// - **片名 / 集名** 优先用弹幕请求里的那两个字段：那是上层拼好的可搜索名字，
    ///   比播放页标题准（标题常带「 · 线路」这类后缀，写进文件名会很难看）；
    /// - **请求头** 直接用 `resource.headers`：与播放本身同一套（站点鉴权都在里面），
    ///   下载时缺一个 header 就会 403。
    /// 交给上层下载。
    ///
    /// 播放页不认识 `AppModel`（见文件顶部的设计说明），下载队列只有上层知道；
    /// `onEnqueueDownloads` 为 nil 表示这个入口没接线 —— 老实回 `.unsupported`，
    /// **不许**当成「已加入队列」糊过去（``DownloadEnqueueOutcome``）。
    private func enqueueViaUpperLayer(
        _ requests: [DownloadRequest],
        siteKey: String,
        title: String
    ) async -> DownloadEnqueueOutcome {
        guard let onEnqueueDownloads else {
            return .unsupported
        }
        return await onEnqueueDownloads(requests, siteKey, title, activeResource.headers)
    }

    func enqueueDownload() async {
        let request = DownloadRequest(
            episode: danmaku?.episode ?? activeTitle,
            line: "",
            url: activeResource.url
        )
        let outcome = await enqueueViaUpperLayer(
            [request],
            siteKey: activeProgressContext?.key.siteKey ?? "",
            title: danmaku?.name ?? activeTitle
        )
        switch outcome {
        case let .added(count):
            downloadNotice = "已加入下载队列 \(count) 条（应用在前台时会自动下）—— 进度在「设置 → 数据 → 下载管理」。"
        case .alreadyQueued:
            downloadNotice = "这一集已经在下载列表里了（同站点 + 同名 + 同集只下一次）。"
        case .unsupported:
            downloadNotice = "这个入口不支持下载（直播 / 临时播放没有站点上下文）。"
        }
    }
}
