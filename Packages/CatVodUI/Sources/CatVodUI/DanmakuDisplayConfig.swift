import Foundation

/// 弹幕显示设置（设置 → 播放 → 弹幕显示）。
///
/// 四项对应上游那套弹幕设置里最常见的四个旋钮：字号 / 透明度 / 速度 / 显示区域。
/// 每个档位都取**可解释**的值（速度给的是「划过整屏的秒数」、区域给的是屏幕高度的比例），
/// 所以界面上不用写死数字，要调也只改这一处。
///
/// 为什么不直接改 `DanmakuDisplayStyle`：
/// - 它是**要持久化**的东西（写进 `UserDefaults` 再读回来，坏值还得能回落），
///   而 `DanmakuDisplayStyle` 是渲染参数；
/// - 两者的**默认值有意一致**：不碰设置就等于 M08h 的行为。默认值不是随手定的，是回归基线，有单测钉住。
public struct DanmakuDisplayConfig: Sendable, Equatable, Hashable {
    /// 字号倍率：乘在弹幕自带的 `size`（常见 25）上。
    public var fontScale: Double
    /// 整层不透明度。
    public var opacity: Double
    /// 速度档位。
    public var speed: DanmakuSpeed
    /// 显示区域：弹幕占屏幕高度的多少。
    public var area: DanmakuArea

    public static let fontScaleRange: ClosedRange<Double> = 0.5 ... 1.6
    public static let opacityRange: ClosedRange<Double> = 0.1 ... 1.0

    public init(
        fontScale: Double = 0.8,
        opacity: Double = 1,
        speed: DanmakuSpeed = .normal,
        area: DanmakuArea = .full
    ) {
        self.fontScale = Self.clamp(fontScale, to: Self.fontScaleRange)
        self.opacity = Self.clamp(opacity, to: Self.opacityRange)
        self.speed = speed
        self.area = area
    }

    /// 夹进范围。
    ///
    /// `init` 与 ``decode(_:)`` 都走它：手改 plist、旧版本写进去的值、`NaN` 都不该把界面搞成
    /// 「字号 0」那种样子。`NaN` 无法比较大小（`min`/`max` 会让它原样穿过去），所以单独挡一道，
    /// 落到下限；±∞ 则按大小正常夹。
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else {
            return range.lowerBound
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 弹幕速度档位。
public enum DanmakuSpeed: Int, Sendable, CaseIterable, Hashable {
    case slow = 1
    case normal = 2
    case fast = 3

    /// 一条滚动弹幕划过整屏的秒数（交给 ``DanmakuPlan/Layout/scrollDuration``）。
    ///
    /// 用「秒数」而不是「倍率」：倍率还要再乘一个基准时长，两处都能改就等于没有唯一口径。
    public var scrollDuration: Double {
        switch self {
        case .slow: 13
        case .normal: 9
        case .fast: 6
        }
    }

    public var title: String {
        switch self {
        case .slow: "慢"
        case .normal: "中"
        case .fast: "快"
        }
    }
}

/// 弹幕显示区域（占屏幕高度的比例，从**顶部**算起）。
///
/// 为什么要它：底部字幕、以及画面下方的人脸最容易被弹幕糊住，把弹幕压在上半屏是常见做法。
///
/// 实现方式不是「画好了再裁」，而是**排版时就只按这个高度算轨道** —— 底部弹幕会跟着区域的
/// 底边走，`DanmakuOverlayGeometry` 一行都不用改（它本来就以「版面高度」为准）。
public enum DanmakuArea: Int, Sendable, CaseIterable, Hashable {
    case quarter = 1
    case half = 2
    case threeQuarters = 3
    case full = 4

    public var fraction: Double {
        switch self {
        case .quarter: 0.25
        case .half: 0.5
        case .threeQuarters: 0.75
        case .full: 1
        }
    }

    public var title: String {
        switch self {
        case .quarter: "1/4 屏"
        case .half: "半屏"
        case .threeQuarters: "3/4 屏"
        case .full: "全屏"
        }
    }
}

// MARK: - 持久化与上屏桥

public extension DanmakuDisplayConfig {
    /// 落 `UserDefaults` 的形态：`字号|透明度|速度|区域`。
    ///
    /// 与 ``DanmakuAPIConfig`` 同一套「竖线拼接」：值里不会出现竖线，读的时候不必处理
    /// 「解码失败」分支 —— 字段数不对就整体回落默认。
    ///
    /// 数值直接用 `String(Double)`（不走 `String(format:)`）：它 locale 无关，
    /// 也不会像格式化那样截掉精度，往返能精确相等。
    var persistenceValue: String {
        [String(fontScale), String(opacity), String(speed.rawValue), String(area.rawValue)]
            .joined(separator: "|")
    }

    /// 从 `UserDefaults` 的字符串还原。
    ///
    /// 格式不对时**整体**回落默认：宁可回到基线，也不要「字号生效了一半、速度没生效」。
    static func decode(_ raw: String?) -> DanmakuDisplayConfig {
        guard let raw, !raw.isEmpty else {
            return DanmakuDisplayConfig()
        }
        let fields = raw.components(separatedBy: "|")
        guard fields.count == 4,
              let fontScale = Double(fields[0]),
              let opacity = Double(fields[1]),
              let speedRaw = Int(fields[2]),
              let speed = DanmakuSpeed(rawValue: speedRaw),
              let areaRaw = Int(fields[3]),
              let area = DanmakuArea(rawValue: areaRaw)
        else {
            return DanmakuDisplayConfig()
        }
        return DanmakuDisplayConfig(fontScale: fontScale, opacity: opacity, speed: speed, area: area)
    }

    /// 转成上屏参数 —— 设置与渲染之间**唯一**的桥。
    ///
    /// `DanmakuDisplayStyle` 只认数值，不认「档位」这类界面概念；反过来，渲染层也不该知道
    /// 「速度」有慢 / 中 / 快。换算只在这里发生一次。
    var style: DanmakuDisplayStyle {
        var style = DanmakuDisplayStyle()
        style.fontScale = fontScale
        style.opacity = opacity
        style.scrollDuration = speed.scrollDuration
        style.areaFraction = area.fraction
        return style
    }
}
