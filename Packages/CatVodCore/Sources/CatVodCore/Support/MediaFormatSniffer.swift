import Foundation

/// 媒体直链嗅探（对应参考实现的 `Sniffer.isVideoFormat`）。
///
/// 用途：CMS 类型站点的播放结果需要判断「这条地址是直链还是要走解析」，
/// 参考实现 `SiteApi.playerContent` 的判定是：
/// `parse = (isVideoFormat(id) && playUrl.isEmpty()) ? 0 : 1`。
public enum MediaFormatSniffer {
    /// 常见媒体扩展名（小写，不含点）。
    public static let videoExtensions: Set<String> = [
        "m3u8", "m3u", "mp4", "m4v", "mkv", "flv", "avi", "mov", "wmv", "webm",
        "ts", "m2ts", "mpd", "mpg", "mpeg", "rmvb", "rm", "3gp", "f4v", "ogv"
    ]

    /// 常见媒体 MIME 片段。
    public static let videoMIMEFragments: [String] = [
        "video/", "application/vnd.apple.mpegurl", "application/x-mpegurl",
        "application/dash+xml", "audio/"
    ]

    /// 判断地址是否像可直接播放的媒体直链。
    public static func isVideoFormat(_ url: String) -> Bool {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return false
        }

        let lowered = text.lowercased()
        if videoMIMEFragments.contains(where: { lowered.contains($0) }) {
            return true
        }

        // 取路径部分并去掉查询串/片段，再判断扩展名。
        let path: Substring
        if let cutoff = lowered.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = lowered[lowered.startIndex..<cutoff]
        } else {
            path = lowered[lowered.startIndex...]
        }
        guard let dotIndex = path.lastIndex(of: ".") else {
            return false
        }
        let ext = String(path[path.index(after: dotIndex)...])
        return videoExtensions.contains(ext)
    }

    /// 本地文件地址（`file:` 前缀）。
    public static func isLocalFileURL(_ url: String) -> Bool {
        url.lowercased().hasPrefix("file:")
    }
}
