import Foundation

/// 一条代理地址（上游 `bean.Proxy` 的 `urls[]` 中的一项）。
///
/// 上游规则（`Proxy.init` / `isValid` / `create` / `isScheme`）：
/// - `scheme`、`host` 必须存在且 `port > 0`，否则该条地址被丢弃；
/// - scheme **以 `http` 开头** → HTTP 代理，**以 `socks` 开头** → SOCKS 代理（因此 `socks5://` 也算）。
public struct ProxyEndpoint: Sendable, Hashable {
    /// 代理协议。
    public enum Scheme: String, Sendable, Hashable {
        case http
        case socks
    }

    public var scheme: Scheme
    public var host: String
    public var port: UInt16
    /// 上游 `Uri.getUserInfo()`，形如 `user:pass`；`ProxyAuthenticator` 用它做代理认证。
    public var userInfo: String?

    public init(scheme: Scheme, host: String, port: UInt16, userInfo: String? = nil) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.userInfo = userInfo
    }

    /// 解析 `http://user:pass@127.0.0.1:1080` / `socks5://127.0.0.1:1080`。
    ///
    /// 解析失败（缺 scheme/host/port、端口越界、协议不认识）返回 nil —— 对应上游把该条地址过滤掉。
    public init?(url text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let schemeText = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let rawPort = components.port, (1 ... 65535).contains(rawPort) else {
            return nil
        }
        let scheme: Scheme
        if schemeText.hasPrefix("http") {
            scheme = .http
        } else if schemeText.hasPrefix("socks") {
            scheme = .socks
        } else {
            return nil
        }
        let userInfo: String?
        if let user = components.user {
            userInfo = components.password.map { "\(user):\($0)" } ?? user
        } else {
            userInfo = nil
        }
        self.init(scheme: scheme, host: host, port: UInt16(rawPort), userInfo: userInfo)
    }

    /// 认证用户名（`userInfo` 里 `:` 前的部分）。
    public var username: String? {
        userInfo.map { String($0.prefix(while: { $0 != ":" })) }
    }

    /// 认证密码（`userInfo` 里 `:` 后的部分；没有 `:` 时为 nil）。
    public var password: String? {
        guard let userInfo, let separator = userInfo.firstIndex(of: ":") else {
            return nil
        }
        return String(userInfo[userInfo.index(after: separator)...])
    }
}
