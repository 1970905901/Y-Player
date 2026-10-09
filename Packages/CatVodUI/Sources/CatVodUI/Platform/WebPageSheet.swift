import SwiftUI
import WebKit

/// 网页条目的落点：**App 内**打开网页（配置中心这类）。
///
/// 为什么不用外部浏览器：宿主跑在 App 进程里（`127.0.0.1`），会话与 cookie 都在这边；
/// 而且用户要能随手关掉回到发现页 —— 跳出去就回不来了。
struct WebPageSheet: View {
    let entry: WebEntry

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WebPageWebView(url: entry.url)
        }
    }

    /// 头部：✕（关闭）+ 域名；右侧放一个同形的隐藏 ✕ 让标题居中（与「筛选站源」同一个形态）。
    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("关闭")
            Spacer()
            Text(entry.url.host ?? entry.url.absoluteString)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .hidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#if os(iOS)
private struct WebPageWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // 网页里的「返回上一页」用系统手势更顺手（配置页有多层）。
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) { }
}
#else
private struct WebPageWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) { }
}
#endif
