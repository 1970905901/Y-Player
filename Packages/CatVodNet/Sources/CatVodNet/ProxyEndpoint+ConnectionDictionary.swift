import CatVodCore
import Foundation

extension ProxyEndpoint {
    /// `URLSessionConfiguration.connectionProxyDictionary` 的形状。
    ///
    /// 键名是系统约定（`HTTPEnable` / `HTTPProxy` / `HTTPPort` …）—— 它们是 CFNetwork 的字符串常量，
    /// `URLSession` 直接读这份字典，没有类型安全的替代写法。
    ///
    /// - **HTTP 代理**：`HTTP` 与 `HTTPS` 两套键都要给。只给 `HTTPS` 的话，明文 HTTP 请求会绕过代理
    ///   —— 那正是「以为走了代理、其实漏了一半」的经典坑；
    /// - **SOCKS**：只有一套键，而且系统**不支持 SOCKS 认证**（用户名密码写了也用不上），
    ///   所以带认证的 SOCKS 代理在这里连不上。这是平台限制，不是我们挑的（见 `docs/任务记录/M06j`）。
    var connectionProxyDictionary: [AnyHashable: Any] {
        switch scheme {
        case .http:
            return [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": Int(port),
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": Int(port),
            ]
        case .socks:
            return [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": Int(port),
            ]
        }
    }
}
