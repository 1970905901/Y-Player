import Foundation

/// 聚合解析页（等价上游 `app/src/main/assets/parse.html`）。
///
/// 上游通过本机 HTTP 服务把页面交给 WebView：`Server.getAddress("/parse?jxs=…&url=…")`，
/// 服务端 `server/process/Parse.java` 读模板再 `String.format(html, jxs, url)`。
/// Apple 侧不需要为它起服务：生成好的 HTML 直接交给 `WKWebView.loadHTMLString` 即可，
/// 因此这里**只保留模板语义** —— 每个 `type=0` 解析器开一个 iframe，地址是「解析器地址 + 待解析地址」。
///
/// 与上游的差别（有意为之）：上游用 `String.format` 把地址直接拼进 JS 源码，
/// 地址里出现引号或 `</script>` 会把页面写坏；这里做最小转义（反斜杠、引号、换行、`<`）。
public enum ParsePageHTML {
    /// 生成页面。
    ///
    /// - Parameters:
    ///   - webParserURLs: `;` 连接的解析器地址（上游的 `jxs` 参数）。
    ///   - webURL: 待解析地址（上游的 `url` 参数）。
    public static func page(webParserURLs: String, webURL: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=yes">
        <title>解析</title>
        </head>
        <body>
        <div id="container"></div>
        <script>
        const jxs = \(jsLiteral(webParserURLs));
        const url = \(jsLiteral(webURL));
        const list = jxs.split(";");
        const container = document.getElementById('container');
        list.forEach(item => {
        const iframe = document.createElement('iframe');
        iframe.src = item + url;
        iframe.sandbox = 'allow-scripts allow-same-origin allow-forms';
        container.appendChild(iframe);
        });
        </script>
        </body>
        </html>
        """
    }

    /// iframe 数量（= 解析器数量；`;` 分隔并忽略空项）。
    public static func frameCount(webParserURLs: String) -> Int {
        webParserURLs.split(separator: ";").filter { !$0.isEmpty }.count
    }

    /// 把文本转成可以安全嵌进 `<script>` 的字面量。
    static func jsLiteral(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "<", with: "\\u003C")
        return "\"\(escaped)\""
    }
}
