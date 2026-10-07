import Foundation

/// 一次 host 的代理选择结果。
public struct ProxySelection: Sendable, Hashable {
    /// 生效的规则名；直连时为空串。
    public var ruleName: String
    /// 该规则下解析出来的代理地址，按配置顺序排列（上游 OkHttp 按顺序失败切换）。
    public var endpoints: [ProxyEndpoint]
    /// 代理认证信息（上游 `Proxy.getUserInfo(host)` 取 `user:pass`）。
    public var userInfo: String?

    public init(ruleName: String = "", endpoints: [ProxyEndpoint] = [], userInfo: String? = nil) {
        self.ruleName = ruleName
        self.endpoints = endpoints
        self.userInfo = userInfo
    }

    /// 直连：本地地址、没有规则、规则命中但没有可用代理，都回落到这里。
    public static let direct = ProxySelection()

    /// 是否直连。
    public var isDirect: Bool {
        endpoints.isEmpty
    }
}

/// 代理规则选择器。
///
/// 对照上游 `OkProxySelector`：
/// 1. `addAll` 后按 `bean.Proxy.compareTo` 排序 —— **非通配规则优先**（`wildcard` 升序）；
///    同优先级保持配置顺序（Java `List.sort` 稳定，这里显式用下标兜底）。
/// 2. `select` 时 `127.0.0.1` / `localhost` 直接回落到系统（本地服务必须能直连自己）。
/// 3. 第一条 `hosts` 命中的规则生效；命中但该规则解析不出代理地址 → 直连。
public struct ProxyRuleResolver: Sendable {
    /// 已按上游顺序排好序的规则。
    public let rules: [ProxyRule]

    public init(rules: [ProxyRule] = []) {
        self.rules = rules.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.hosts.contains { HostRuleMatcher.isWildcard($0) }
                let right = rhs.element.hosts.contains { HostRuleMatcher.isWildcard($0) }
                if left == right {
                    return lhs.offset < rhs.offset
                }
                return !left
            }
            .map(\.element)
    }

    /// 没有任何规则。
    public var isEmpty: Bool {
        rules.isEmpty
    }

    /// 按 host 选择代理。
    public func selection(forHost host: String) -> ProxySelection {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !rules.isEmpty, !lowered.isEmpty, !Self.isLocal(host: lowered) else {
            return .direct
        }
        for rule in rules {
            guard HostRuleMatcher.firstMatch(text: lowered, rules: rule.hosts) != nil else {
                continue
            }
            let endpoints = rule.urls.compactMap(ProxyEndpoint.init(url:))
            guard !endpoints.isEmpty else {
                return .direct
            }
            return ProxySelection(
                ruleName: rule.name,
                endpoints: endpoints,
                userInfo: endpoints.first { $0.userInfo != nil }?.userInfo
            )
        }
        return .direct
    }

    /// 本地地址判定：上游只放行 `127.0.0.1` / `localhost`，这里额外放行 IPv6 回环
    /// （本项目的本地服务同时可能出现 `::1` 形式的访问）。
    public static func isLocal(host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1" || lowered == "[::1]"
    }
}
