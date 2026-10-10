import Foundation

/// `/proxy` 落盘文件的暂存处（M06b 的流式转发）。
///
/// 为什么需要它：媒体文件可能几十 GB，缓冲转发会撞 ``LocalProxyUpstreamClient/maximumBodyBytes``；
/// 响应体先落盘、再由本机服务流给播放器。**写盘容易清盘难** —— FlyingFox 的响应体没有
/// 「发完了」的回调，所以清扫用「定期 + 宽限期」：每次新请求顺手清一遍超过 ``maximumAge`` 的旧文件；
/// 上次进程被杀留下的残渣也会在下一次请求时被清掉。
///
/// 为什么 15 分钟的宽限是安全的：文件是**下载完成后**才开始发的（写的时候没人读），
/// 而发送走的是回环 —— 再大的文件也在一两分钟内发完。
public enum LocalProxyTempFiles {
    /// 宽限期：比任何一次回环发送都宽得多。
    public static let maximumAge: TimeInterval = 15 * 60

    /// 暂存目录：`<系统临时目录>/YPlayerProxy`。
    public static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("YPlayerProxy", isDirectory: true)
    }

    /// 造一个新的暂存文件地址（目录不存在就建）。
    public static func makeFileURL() throws -> URL {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + ".tmp", isDirectory: false)
    }

    /// 清掉超过 ``maximumAge`` 的旧文件（目录不存在就什么都不做）。
    public static func sweep(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory(),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > maximumAge else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }
}
