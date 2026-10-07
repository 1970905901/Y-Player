import Foundation

/// 就绪信号解析（`docs/js2p宿主契约.md` 第 3 条）。
///
/// bundle 在 listen 成功后固定打印：
/// `CatVodSpiderios listening on http://127.0.0.1:<port>`
/// 其中 `<port>` 取自 `server.address().port`，是**实际**端口 ——
/// 因此 `EADDRINUSE` 自动 +1 重试后的真实端口也能拿到，宿主不需要自己猜。
public enum NodeReadiness {
    /// 就绪行固定标记。
    public static let readyMarker = "CatVodSpiderios listening on"
    /// 端口占用重试行（bundle 会打印 4 次以内），仅用于诊断。
    public static let portConflictMarker = "is already in use. Trying next available port"

    /// 从一行输出里解析实际端口；不是就绪行则返回 nil。
    public static func port(fromLine line: String) -> Int? {
        guard let marker = line.range(of: readyMarker) else {
            return nil
        }
        let tail = line[marker.upperBound...]
        // 形如 " http://127.0.0.1:9988"：取最后一个冒号后的连续数字。
        guard let colon = tail.lastIndex(of: ":") else {
            return nil
        }
        let digits = tail[tail.index(after: colon)...].prefix { $0.isNumber }
        guard !digits.isEmpty, let port = Int(digits), (1 ... 65535).contains(port) else {
            return nil
        }
        return port
    }

    /// 是否为就绪行。
    public static func isReadyLine(_ line: String) -> Bool {
        port(fromLine: line) != nil
    }

    /// 是否为「端口被占用、正在尝试下一个端口」的诊断行。
    public static func isPortConflictLine(_ line: String) -> Bool {
        line.contains(portConflictMarker)
    }

    /// 就绪行对应的 baseURL（局部回环地址，契约里的 `x.url`）。
    public static func baseURL(port: Int) -> URL? {
        URL(string: "http://127.0.0.1:\(port)")
    }
}
