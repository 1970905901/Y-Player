@testable import CatVodUI
import Foundation
import Testing

/// 下载列表的进度文案（M25P2 收尾）：知道总量才写分母，不知道不冒充。
@Suite("下载列表：进度文案")
struct DownloadProgressTextTests {
    @Test("HLS 运行中：报字节 + 片段数 —— 中途不知道总量就不写分母")
    func runningWithSegments() {
        let text = DownloadProgressText.running(received: 700, expected: 0, completedSegments: 3, totalSegments: 12)
        #expect(text == "已下 \(StorageSpace.format(700)) · 3/12 片")
    }

    @Test("直链运行中：总量知道就写清「下了多少 / 一共多大」")
    func runningDirectWithTotal() {
        let text = DownloadProgressText.running(received: 700, expected: 4000, completedSegments: 0, totalSegments: 0)
        #expect(text == "已下 \(StorageSpace.format(700)) / \(StorageSpace.format(4000))")
    }

    @Test("直链没有 Content-Length：只说下了多少，不把总量当成 0 字节")
    func runningDirectWithoutTotal() {
        let text = DownloadProgressText.running(received: 700, expected: 0, completedSegments: 0, totalSegments: 0)
        #expect(text == "已下 \(StorageSpace.format(700))")
    }

    @Test("暂停的直链：账目里的总量也一起报（继续时只补剩下的）")
    func pausedDirectWithTotal() {
        let text = DownloadProgressText.paused(received: 700, expected: 4000)
        #expect(text == "已下 \(StorageSpace.format(700)) / \(StorageSpace.format(4000))")
    }

    @Test("总量不比下过的多（对不上 / 到齐）：只报下了多少，不写出一个反的分母")
    func pausedWithoutUsableTotal() {
        #expect(DownloadProgressText.paused(received: 700, expected: 700) == "已下 \(StorageSpace.format(700))")
        #expect(DownloadProgressText.paused(received: 700, expected: 0) == "已下 \(StorageSpace.format(700))")
    }
}
