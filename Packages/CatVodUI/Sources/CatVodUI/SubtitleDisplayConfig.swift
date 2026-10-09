import Foundation

/// 字幕显示设置（设置 → 播放 → 字幕显示）。
///
/// 四项：**显示开关 / 字号 / 位置 / 背景**。取值都取可解释的形态（位置是「底边距的倍率」、
/// 背景是「那层底的不透明度」），所以界面上不用写死数字，要调也只改这一处。
///
/// 与 `DanmakuDisplayConfig` 同一套做法与理由：它是**要持久化**的东西（坏值得能回落），
/// 而 `SubtitleDisplayStyle` 是渲染参数；两者的**默认值有意一致** ——
/// 不碰设置就等于 M09f 的行为，默认值是回归基线（有单测钉住）。
public struct SubtitleDisplayConfig: Sendable, Equatable, Hashable {
    /// 是否显示字幕。
    ///
    /// 只管显示：字幕要不要去取，取决于站点给没给 `subs`（那是另一件事）。
    /// 关掉时覆盖层直接不挂上去，所以是**立刻消失**，不用重进页面。
    public var isVisible: Bool
    /// 字号倍率：乘在 `SubtitleDisplayStyle.baseFontSize` 上。
    public var fontScale: Double
    /// 垂直位置。
    public var position: SubtitlePosition
    /// 文字背后的底色。
    public var background: SubtitleBackground

    public static let fontScaleRange: ClosedRange<Double> = 0.5 ... 1.6

    public init(
        isVisible: Bool = true,
        fontScale: Double = 1,
        position: SubtitlePosition = .low,
        background: SubtitleBackground = .translucent
    ) {
        self.isVisible = isVisible
        self.fontScale = Self.clamp(fontScale, to: Self.fontScaleRange)
        self.position = position
        self.background = background
    }

    /// 夹进范围。`init` 与 ``decode(_:)`` 都走它：手改 plist、旧版本写进去的值、`NaN`
    /// 都不该把界面搞成「字号 0」那种样子（`NaN` 落下限、±∞ 按大小夹）。
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else {
            return range.lowerBound
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 字幕的垂直位置。
///
/// 取的是**底边距的倍率**，而不是「画面高度的百分比」：这样「低」这一档与原行为逐点相等
/// （默认档必须等于上一版，才谈得上「不碰设置就什么都不变」），其余档再往外推。
public enum SubtitlePosition: Int, Sendable, CaseIterable, Hashable {
    case low = 1
    case middle = 2
    case high = 3

    /// 乘在基准底边距上。
    public var insetScale: Double {
        switch self {
        case .low: 1
        case .middle: 2.5
        case .high: 5
        }
    }

    public var title: String {
        switch self {
        case .low: "低"
        case .middle: "中"
        case .high: "高"
        }
    }
}

/// 字幕文字背后的底色。
public enum SubtitleBackground: Int, Sendable, CaseIterable, Hashable {
    /// 不要底，只靠白字加深色阴影。
    case none = 1
    /// 半透明黑底（默认）。
    case translucent = 2
    /// 更实的黑底：画面特别花时用。
    case solid = 3

    /// 那层黑底的不透明度。
    public var opacity: Double {
        switch self {
        case .none: 0
        case .translucent: 0.55
        case .solid: 0.9
        }
    }

    public var title: String {
        switch self {
        case .none: "无"
        case .translucent: "半透明"
        case .solid: "深色"
        }
    }
}

// MARK: - 持久化与上屏桥

public extension SubtitleDisplayConfig {
    /// 落 `UserDefaults` 的形态：`显示|字号|位置|背景`。
    ///
    /// 与 `DanmakuAPIConfig` / `DanmakuDisplayConfig` 同一套竖线拼接：值里不会出现竖线，
    /// 读的时候不必处理解码失败分支 —— 字段数不对就整体回落默认。
    /// 数值用 `String(Double)`（locale 无关、往返精确）。
    var persistenceValue: String {
        [
            isVisible ? "1" : "0",
            String(fontScale),
            String(position.rawValue),
            String(background.rawValue),
        ].joined(separator: "|")
    }

    /// 从 `UserDefaults` 的字符串还原；格式不对时**整体**回落默认。
    static func decode(_ raw: String?) -> SubtitleDisplayConfig {
        guard let raw, !raw.isEmpty else {
            return SubtitleDisplayConfig()
        }
        let fields = raw.components(separatedBy: "|")
        guard fields.count == 4,
              let fontScale = Double(fields[1]),
              let positionRaw = Int(fields[2]),
              let position = SubtitlePosition(rawValue: positionRaw),
              let backgroundRaw = Int(fields[3]),
              let background = SubtitleBackground(rawValue: backgroundRaw)
        else {
            return SubtitleDisplayConfig()
        }
        return SubtitleDisplayConfig(
            isVisible: fields[0] == "1",
            fontScale: fontScale,
            position: position,
            background: background
        )
    }

    /// 转成上屏参数 —— 设置与渲染之间**唯一**的桥。
    ///
    /// `SubtitleDisplayStyle` 只认数值，不认「低 / 中 / 高」「半透明 / 深色」这类界面概念。
    internal var style: SubtitleDisplayStyle {
        var style = SubtitleDisplayStyle()
        style.fontScale = fontScale
        style.bottomInset *= position.insetScale
        style.backgroundOpacity = background.opacity
        return style
    }
}
