import Foundation

/// 解析成功的产物：可直接交给播放器的地址 + header + 是哪个解析器给出来的。
///
/// 上游 `ParseJob.onParseSuccess(headers, url, from)` 的对应物；`type=1`（JSON）与
/// `type=0`（Web 嗅探，M5c）都返回它，调用方不必区分解析通道。
public struct ParsedPlayback: Sendable, Hashable {
    /// 解析出来的播放地址。
    public var url: String
    /// 随地址一起生效的请求 header（响应里取到的优先，否则是解析器/结果的 header）。
    public var headers: [String: String]
    /// 来源解析器名（上游的 `from`；空表示匿名解析器，例如 `json:` 前缀建的临时解析器）。
    public var from: String

    public init(url: String, headers: [String: String] = [:], from: String = "") {
        self.url = url
        self.headers = headers
        self.from = from
    }
}
