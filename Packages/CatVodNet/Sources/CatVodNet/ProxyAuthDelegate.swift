import CatVodCore
import Foundation

/// 代理认证：只回答**代理**的认证挑战，站点的认证挑战一律交回系统默认处理。
///
/// 为什么单独立一个类：`URLSession` 把「代理要认证」和「站点要认证」塞进同一个回调，
/// 只能靠 `protectionSpace.proxyType` 区分。分不清的后果很实在 ——
/// 我们会拿代理的用户名密码去回答站点的 401：既泄漏了凭据，又照样登不上。
///
/// `@unchecked Sendable` 的成立条件：**状态全是 `let`**，delegate 自身无可变状态。
final class ProxyAuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let credential: URLCredential?

    /// 从端点取凭据；端点里没写 `user:pass` 就没有凭据（挑战交回系统处理）。
    init(endpoint: ProxyEndpoint) {
        guard let user = endpoint.username else {
            credential = nil
            return
        }
        credential = URLCredential(user: user, password: endpoint.password ?? "", persistence: .none)
    }

    /// 该不该由我们用代理凭据回答这次挑战：**只有代理的挑战才答**（站点认证不碰）。
    ///
    /// 抽成纯函数是为了能测：`URLProtectionSpace.proxyType` 只有系统为代理生成的保护空间才有值，
    /// 测试里造不出真的代理挑战 —— 那就把「判断」本身拿出来测，delegate 只负责调用它。
    static func shouldAnswer(proxyType: String?, hasCredential: Bool) -> Bool {
        hasCredential && proxyType != nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard Self.shouldAnswer(
            proxyType: challenge.protectionSpace.proxyType,
            hasCredential: credential != nil
        ), let credential else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, credential)
    }
}
