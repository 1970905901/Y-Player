import Foundation

// 站点能力判定：把「站点怎么跑、能不能跑」的判断集中在 Core，便于单测与 UI 复用。

public extension Site {
    /// 归一化后的站点类型；未知取值返回 nil。
    var kind: SiteKind? {
        SiteKind(rawValue: type)
    }

    /// 是否为 js2p / CatSpider HTTP 站点。
    ///
    /// 判定与参考实现 `app/.../api/loader/CatSpider.java` 的 `matches(api)` 完全一致：
    /// `api` 以 `http` 开头且包含 `/spider/`。
    var isCatSpiderHTTP: Bool {
        api.hasPrefix("http") && api.contains("/spider/")
    }

    /// `type=3` 的运行时分发结果。
    var spiderRuntimeKind: SpiderRuntimeKind {
        guard kind == .spider else {
            return .unsupported
        }
        if isCatSpiderHTTP {
            return .catSpiderHTTP
        }
        let lowered = api.lowercased()
        if lowered.contains(".py") {
            return .python
        }
        if lowered.contains(".js") {
            return .javaScript
        }
        if api.hasPrefix("csp_") {
            return .jarJava
        }
        return .unsupported
    }

    /// 搜索可用性。
    var searchAvailability: FeatureAvailability {
        FeatureAvailability(rawValue: searchable) ?? .enabled
    }

    /// 换源可用性。
    var changeSourceAvailability: FeatureAvailability {
        FeatureAvailability(rawValue: changeable) ?? .enabled
    }

    /// 是否参与快速搜索。
    var isQuickSearchEnabled: Bool {
        quickSearch == 1
    }

    /// 该站点在当前平台/构建中是否可运行；不可用时给出可展示的原因。
    var availability: SiteAvailability {
        if key.isEmpty {
            return .unavailable(reason: "站点缺少 key")
        }
        if api.isEmpty {
            return .unavailable(reason: "站点缺少 api")
        }
        guard let kind else {
            return .unavailable(reason: "未知站点类型 type=\(type)")
        }
        switch kind {
        case .xmlApi, .jsonApi, .jsonApiCompat, .httpApiBase64Ext:
            return .available
        case .spider:
            switch spiderRuntimeKind {
            case .catSpiderHTTP, .javaScript:
                return .available
            case .jarJava:
                return .unavailable(reason: "需要 JVM，Apple 平台不支持 csp_*.jar 站点")
            case .python:
                return .unavailable(reason: "需要 Python 运行时，本构建未包含")
            case .unsupported:
                return .unavailable(reason: "无法识别的 Spider api：\(api)")
            }
        }
    }
}
