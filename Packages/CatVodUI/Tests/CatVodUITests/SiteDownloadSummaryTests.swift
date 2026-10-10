@testable import CatVodUI
import Foundation
import Testing

/// 逐集换地址下载的结果文案（M10i 下半场）：三样都要写清，不能拿「已排 N 集」盖住失败。
@Suite("整部下载（逐集换地址）结果文案")
struct SiteDownloadSummaryTests {
    @Test("全部排上：只写一句")
    func allQueued() {
        #expect(SiteDownloadSummary.text(queued: 3, alreadyQueued: 0, failed: 0) == "已排 3 集。")
    }

    @Test("有本来就在队列里的：分开写，不算失败")
    func someAlreadyQueued() {
        let text = SiteDownloadSummary.text(queued: 2, alreadyQueued: 1, failed: 0)
        #expect(text == "已排 2 集，1 集本来就在队列里。")
    }

    @Test("有换不到地址的：写清数量 + 给一条可执行的下一步")
    func withFailures() {
        let text = SiteDownloadSummary.text(queued: 1, alreadyQueued: 0, failed: 2)
        #expect(text.contains("已排 1 集"))
        #expect(text.contains("2 集换不到地址"))
        #expect(text.contains("下载本集"))
    }

    @Test("一集都没轮到：不装作排上了")
    func nothingToDo() {
        #expect(SiteDownloadSummary.text(queued: 0, alreadyQueued: 0, failed: 0) == "没有可下载的集。")
    }
}
