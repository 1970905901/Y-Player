import CatVodCore
import Combine
import Foundation
import WebKit

/// 一次 Web 嗅探会话：对齐上游 `CustomWebView`
/// （webhtv `app/src/main/java/com/fongmi/android/tv/ui/custom/CustomWebView.java`）。
///
/// **平台差异（决定了实现方式，不要按 Android 的写法照抄）**：
/// Android 能拦截**每一个子请求**（`WebViewClient.shouldInterceptRequest`）：
/// XHR、iframe、媒体分片全看得见；Apple 的 WebKit 没有等价 API
/// （`WKURLSchemeHandler` 只对自定义 scheme 生效，`decidePolicyFor` 只看导航请求）。
/// 因此这里用三条通道合起来逼近上游行为：
/// 1. **导航回调**：主框架 / iframe 的每次导航都当候选地址（能拿到该请求的 header）；
/// 2. **JS 注入**：包一层 `XMLHttpRequest.open` / `window.fetch` / `HTMLMediaElement.src`，
///    把地址经 `WKScriptMessageHandler` 报上来（等价上游「看得见 XHR」）；
/// 3. **页面加载完**：扫一遍 `<video>/<audio>/<source>/<iframe>` 的地址，并执行规则脚本
///    （等价上游 `onPageFinished` → `Sniffer.getScript`）。
///
/// 判定一律交给 ``SniffRules``（与 JSON 侧同一份规则），平台层不重复实现任何协议逻辑。
///
/// 已知限制（写在这里而不是藏着）：
/// - 不是**所有**子请求都能被看见（例如图片/普通脚本请求）—— 但那些本来不是媒体地址，判定也不会通过；
/// - 内层播放页（`PLAYER` 正则命中）会另开一个 WebView 嗅探，这个 WebView 不在视图层级里，
///   iOS 可能对它降频；页面上要求人机验证时本实现会把页面**显示出来**让用户自己过（见 ``requiresUserInteraction``）。
@MainActor
final class WebSniffSession: NSObject, ObservableObject {
    /// 一次嗅探的全部输入。
    struct Request {
        /// 页面地址（`type=0` 是「解析器地址 + 待解析地址」，与上游 `startWeb(key, item, webUrl)` 一致）。
        var url: String = ""
        /// 直接给的页面 HTML（`type=4` 的聚合页，见 ``ParsePageHTML``）；非 nil 时用 `loadHTMLString`。
        var html: String?
        /// 页面 header（已经过 ``WebSniffHeaders`` 收敛）。
        var headers: [String: String] = [:]
        /// 点击脚本（站点级优先，上游 `getClick` 的结论）。
        var click: String = ""
        /// 超时（秒）：上游 `Constant.TIMEOUT_PARSE_WEB` = 15。
        var timeout: TimeInterval = ParseJobResolver.defaultTimeout
        /// 嗅探规则与广告表。
        var rules = SniffRules()
        /// 是否对命中的「播放页」再开一层嗅探（上游 `start(...)` 的 `detect` 参数）。
        var detectsPlayerPages = true
        /// 来源说明（写进 ``ParsedPlayback/from``）。
        var from: String = ""

        init() {}
    }

    /// 嗅探成功（`from` 为来源说明）。
    var onSuccess: ((ParsedPlayback) -> Void)?
    /// 嗅探失败（可读原因）。
    var onFailure: ((String) -> Void)?
    /// 站点要求人机验证时置为 true：界面应当把页面**显示出来**让用户自己过（上游此时弹对话框）。
    @Published private(set) var requiresUserInteraction = false

    private(set) var webView: WKWebView?
    private var request: Request?
    private var timeoutTask: Task<Void, Never>?
    private var detectedPages = SniffedPageList()
    private var nested: WebSniffSession?
    private var isFinished = false

    /// 脚本消息通道名（注入脚本与控制端共用）。
    static let messageHandlerName = "yplayer"

    /// 回落浏览器 UA。
    ///
    /// 上游回填的是「WebView 自己的 UA」；Apple 侧新建的 `WKWebView` 在加载前读不到真实 UA
    /// （`customUserAgent` 为 nil），所以这里用一个标准 Safari UA 顶上 —— 它只在
    /// 「源给的是播放器 UA」时才会被用到（语义见 ``WebSniffHeaders/forPage(headers:fallbackUserAgent:)``）。
    static let fallbackBrowserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
        + " (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 创建（或复用）承载用的 WebView；由 ``WebSniffWebView`` 放进视图层级。
    func makeWebView() -> WKWebView {
        if let webView {
            return webView
        }
        let controller = WKUserContentController()
        controller.add(self, name: Self.messageHandlerName)
        controller.addUserScript(WKUserScript(
            source: Self.injectedScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        let created = WKWebView(frame: .zero, configuration: configuration)
        created.navigationDelegate = self
        webView = created
        return created
    }

    /// 开始嗅探（重复调用会复位上一次的状态）。
    func start(_ request: Request) {
        self.request = request
        detectedPages = SniffedPageList()
        isFinished = false
        requiresUserInteraction = false
        let webView = makeWebView()
        let pageHeaders = WebSniffHeaders.forPage(
            headers: request.headers,
            fallbackUserAgent: webView.customUserAgent ?? Self.fallbackBrowserUserAgent
        )
        apply(pageHeaders: pageHeaders, to: webView)
        if let html = request.html {
            webView.loadHTMLString(html, baseURL: nil)
        } else if let url = URL(string: request.url) {
            var urlRequest = URLRequest(url: url)
            for (key, value) in pageHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
            webView.load(urlRequest)
        } else {
            fail("解析页地址无效：\(request.url.prefix(120))")
            return
        }
        startTimeout(request.timeout)
    }

    /// 结束会话（成功 / 失败 / 取消都在这里收口，保证只会回调一次）。
    func stop() {
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        nested?.stop()
        nested = nil
    }

    // MARK: - 内部：生命周期

    /// 结束并上报成功。
    fileprivate func finish(with playback: ParsedPlayback) {
        guard !isFinished else {
            return
        }
        stop()
        onSuccess?(playback)
    }

    /// 结束并上报失败。
    fileprivate func fail(_ reason: String) {
        guard !isFinished else {
            return
        }
        stop()
        onFailure?(reason)
    }

    /// 超时（上游 `TIMEOUT_PARSE_WEB`）：页面在时限内没给出可识别地址就算失败，不许一直转圈。
    private func startTimeout(_ seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 1) * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            self?.fail("解析超时（\(Int(seconds)) 秒）：页面没有给出可识别的媒体地址。")
        }
    }

    /// 把页面 header 落到 WebView：UA 走 `customUserAgent`，Cookie 走 `WKHTTPCookieStore`（上游 `checkHeader`）。
    private func apply(pageHeaders: [String: String], to webView: WKWebView) {
        for (key, value) in pageHeaders {
            if WebSniffHeaders.isUserAgent(key) {
                webView.customUserAgent = value
            } else if key.lowercased() == "cookie" {
                apply(cookieHeader: value, to: webView)
            }
        }
    }

    /// 把 `Cookie: a=1; b=2` 这种整串写进 Cookie 存储（域名取解析页的 host）。
    private func apply(cookieHeader: String, to webView: WKWebView) {
        guard let host = request.flatMap({ URL(string: $0.url)?.host }) else {
            return
        }
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else {
                continue
            }
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: parts[0],
                .value: parts[1],
                .domain: host,
                .path: "/",
            ]
            guard let cookie = HTTPCookie(properties: properties) else {
                continue
            }
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
    }

    /// 页面加载完：执行规则脚本，并把点击脚本放最前（上游 `onPageFinished` → `Sniffer.getScript` + `click`）。
    private func runPageScripts() {
        guard let webView, let request, !isFinished else {
            return
        }
        var scripts = request.rules.scripts(forURL: request.url)
        let click = request.click.trimmingCharacters(in: .whitespacesAndNewlines)
        if !click.isEmpty, !scripts.contains(click) {
            scripts.insert(click, at: 0)
        }
        run(scripts, at: 0, in: webView)
    }

    /// 顺序执行脚本（上游 `evaluate(script, index)`：等上一条执行完再下一条）。
    private func run(_ scripts: [String], at index: Int, in webView: WKWebView) {
        guard index < scripts.count, !isFinished else {
            return
        }
        webView.evaluateJavaScript(scripts[index]) { [weak self] _, _ in
            Task { @MainActor in
                self?.run(scripts, at: index + 1, in: webView)
            }
        }
    }

    /// 判定一条候选地址：命中即成功（带该请求的 header）。
    ///
    /// 返回是否「已经处理掉」（成功或需要人机验证），调用方据此决定要不要放行这次导航。
    @discardableResult
    fileprivate func consider(url: String, headers: [String: String]) -> Bool {
        guard !isFinished, let request else {
            return false
        }
        if url.contains("/cdn-cgi/challenge-platform/") {
            // 上游此时弹对话框让用户过验证；这里把页面显示出来（界面读 requiresUserInteraction）。
            requiresUserInteraction = true
            return false
        }
        guard request.rules.decision(forURL: url).isMedia else {
            return false
        }
        finish(with: ParsedPlayback(url: url, headers: headers, from: request.from))
        return true
    }

    /// 命中的「播放页」要不要再开一层（上游 `PLAYER` 正则 + `addUrl` 去重 + 内层 `detect = false`）。
    fileprivate func nestedRequest(for url: String) -> Request? {
        guard var request, request.detectsPlayerPages, SniffRules.isPlayerPage(url) else {
            return nil
        }
        guard detectedPages.insert(url) else {
            return nil
        }
        request.url = url
        request.html = nil
        request.headers = [:]
        request.detectsPlayerPages = false
        return request
    }

    /// 开一个内层会话：它的成功直接算父会话成功；失败不急着上报（等父会话自己的超时或导航错误）。
    ///
    /// 说明：上游会为内层播放页弹一个可见窗口；这里的内层 WebView 不进视图层级
    /// （iOS 可能降频，但 XHR/媒体探测仍会执行），限制已写在类型文档里。
    fileprivate func startNested(_ request: Request) {
        let session = WebSniffSession()
        session.onSuccess = { [weak self] playback in
            self?.finish(with: playback)
        }
        session.start(request)
        nested = session
    }
}

// MARK: - 导航与脚本回调

extension WebSniffSession: WKNavigationDelegate {
    /// 上游 `shouldInterceptRequest` 的对应物：每次导航都当候选地址，广告 host 直接拦掉。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url?.absoluteString else {
            decisionHandler(.allow)
            return
        }
        let rules = request?.rules ?? SniffRules()
        if let host = navigationAction.request.url?.host, rules.isAd(host: host) {
            // 上游：广告 host 直接返回空响应（不加载）。
            decisionHandler(.cancel)
            return
        }
        if let nested = nestedRequest(for: url) {
            decisionHandler(.cancel)
            startNested(nested)
            return
        }
        if consider(url: url, headers: navigationAction.request.allHTTPHeaderFields ?? [:]) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// 页面加载完：注入规则脚本（上游 `onPageFinished`）。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        runPageScripts()
    }

    /// 主框架加载失败就算这次解析失败。
    ///
    /// 与上游的差别：上游 `onReceivedError` 只记日志、靠 15 秒超时兜底；这里直接给可读原因，
    /// 少让用户干等一次超时。`navigation == nil` 表示失败来自子框架，不算整体失败。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard navigation != nil else {
            return
        }
        fail("解析页加载失败：\(error.localizedDescription)")
    }

    /// 同上：主框架在「还没提交」阶段就失败。
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard navigation != nil else {
            return
        }
        fail("解析页加载失败：\(error.localizedDescription)")
    }

    /// 解析页的证书错误继续走（上游 `onReceivedSslError` 里 `handler.proceed()`）：
    /// 有些源的解析页证书链不完整；真正播放用的仍是系统播放器自己的校验。
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

extension WebSniffSession: WKScriptMessageHandler {
    /// JS 报上来的候选地址（注入脚本里的 `window.webkit.messageHandlers.yplayer`）。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName, let url = message.body as? String else {
            return
        }
        consider(url: url, headers: [:])
    }
}

extension WebSniffSession {
    /// 注入脚本：把「请求型」地址报上来。
    ///
    /// 上游靠拦截每个请求实现；Apple 侧只能包这些入口 + 导航回调，覆盖面略小（类型文档已记录）。
    static let injectedScript = #"""
    (function () {
        if (window.__yplayerSniffInstalled) return;
        window.__yplayerSniffInstalled = true;
        var post = function (url) {
            if (!url) return;
            try { window.webkit.messageHandlers.yplayer.postMessage(String(url)); } catch (e) {}
        };
        var open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
            post(url);
            return open.apply(this, arguments);
        };
        var originalFetch = window.fetch;
        if (originalFetch) {
            window.fetch = function (input) {
                if (typeof input === 'string') post(input);
                else if (input && input.url) post(input.url);
                return originalFetch.apply(this, arguments);
            };
        }
        var descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (descriptor && descriptor.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                set: function (value) { post(value); descriptor.set.call(this, value); },
                get: descriptor.get,
                configurable: true
            });
        }
        document.addEventListener('DOMContentLoaded', function () {
            var nodes = document.querySelectorAll('video, audio, source, iframe');
            for (var index = 0; index < nodes.length; index++) {
                post(nodes[index].src || nodes[index].currentSrc);
            }
        });
    })();
    """#
}
