import SwiftUI
import WebKit

#if canImport(UIKit)
/// iOS / iPadOS：把 ``WebSniffSession`` 的 WebView 放进视图层级。
struct SniffWebViewHost: UIViewRepresentable {
    @ObservedObject var session: WebSniffSession

    func makeUIView(context: Context) -> WKWebView {
        session.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
/// macOS：同上，走 `NSViewRepresentable`。
struct SniffWebViewHost: NSViewRepresentable {
    @ObservedObject var session: WebSniffSession

    func makeNSView(context: Context) -> WKWebView {
        session.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

/// 嗅探期的页面容器。
///
/// 为什么必须放进视图层级：WebKit 对不在层级里的 WebView 会降频（iOS 尤其明显），
/// 页面脚本可能迟迟不跑 —— 而嗅探正是靠页面脚本跑起来才发现真实地址。
/// 所以平时把它缩到 1pt（几乎不可见），一旦命中人机验证就放大到 320pt 让用户自己操作
/// （上游此时弹对话框，见 `docs/任务记录/M05c-Web嗅探与聚合.md`）。
struct WebSniffWebView: View {
    @ObservedObject var session: WebSniffSession

    private var isExpanded: Bool {
        session.requiresUserInteraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                Label("站点要求在下方页面完成人机验证", systemImage: "hand.raised")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SniffWebViewHost(session: session)
                .frame(height: isExpanded ? 320 : 1)
                .opacity(isExpanded ? 1 : 0.01)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
