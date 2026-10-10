import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

/// 卡片样式换算（M23P1）：配置说圆的就圆、说多宽就多宽；**没声明就保持 2:3**。
@Suite("卡片样式换算")
struct PosterCardLayoutTests {
    @Test("没有样式：保持参考视频的 2:3（不跟 CardStyle 的兜底值走）")
    func noStyleKeepsReferenceRatio() {
        #expect(PosterCardLayout.ratio(for: nil) == CGFloat(2.0 / 3.0))
        #expect(!PosterCardLayout.isCircular(nil))
    }

    @Test("声明了 ratio：用它（作者那套配置就是 1.433 的横幅）")
    func explicitRatio() {
        let style = CardStyle(type: "rect", ratio: 1.433)
        #expect(abs(PosterCardLayout.ratio(for: style) - 1.433) < 0.0001)
        #expect(!PosterCardLayout.isCircular(style))
    }

    @Test("oval / circle=1：圆形卡，比例按 1:1")
    func ovalIsCircular() {
        let oval = CardStyle(type: "oval", ratio: 0)
        #expect(PosterCardLayout.isCircular(oval))
        #expect(PosterCardLayout.ratio(for: oval, circular: true) == 1)

        let circleFlag = CardStyle(type: "rect", ratio: 0, circle: 1)
        #expect(PosterCardLayout.isCircular(circleFlag))
    }

    @Test("land=1：当 rect 处理（上游等价规则），比例仍按配置")
    func landIsRect() {
        let land = CardStyle(type: "list", ratio: 0, land: 1)
        #expect(!PosterCardLayout.isCircular(land))
        // land=1 且没写 ratio：上游等价 rect + 1.33
        #expect(abs(PosterCardLayout.ratio(for: land) - 1.33) < 0.0001)
    }
}
