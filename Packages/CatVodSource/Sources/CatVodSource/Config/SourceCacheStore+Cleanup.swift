import CatVodCore
import Foundation

// 缓存清理动作：手动清理、清残留、按容量上限淘汰。

public extension SourceCacheStore {
    /// 删除指定缓存文件（不存在则静默忽略）。
    func remove(fileName: String) throws {
        let target = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: target.path) else {
            return
        }
        try fileManager.removeItem(at: target)
    }

    /// 清空全部缓存，返回删除的文件数。
    @discardableResult
    func clear() throws -> Int {
        let all = try entries()
        for entry in all {
            try remove(fileName: entry.fileName)
        }
        return all.count
    }

    /// 清掉**不属于** `currentURL` 的缓存（换接口后的 6 MB 残留），返回删除的文件数。
    ///
    /// - Parameter currentURL: 当前接口地址；传 nil 表示「当前没有可用接口」，此时全部视为残留。
    @discardableResult
    func pruneOrphans(currentURL: URL?) throws -> Int {
        let orphans = try entries(currentURL: currentURL).filter { !$0.isCurrent }
        for entry in orphans {
            try remove(fileName: entry.fileName)
        }
        return orphans.count
    }

    /// 超过 ``maxByteCount`` 时按「最近修改时间从旧到新」淘汰，返回删除的文件数。
    ///
    /// 约定：**当前接口的缓存永远不会被淘汰**（否则切回旧接口要重下 6 MB）；
    /// 若只剩当前接口的缓存且仍超限，则保留并停止淘汰。
    @discardableResult
    func enforceLimit(currentURL: URL?) throws -> Int {
        var all = try entries(currentURL: currentURL)
        var total = all.reduce(Int64(0)) { $0 + $1.byteCount }
        var removed = 0
        while total > maxByteCount {
            guard let victim = all.last(where: { !$0.isCurrent }) else {
                break
            }
            try remove(fileName: victim.fileName)
            total -= victim.byteCount
            removed += 1
            all.removeAll { $0.fileName == victim.fileName }
        }
        return removed
    }
}
