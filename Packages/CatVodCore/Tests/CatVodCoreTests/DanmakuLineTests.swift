@testable import CatVodCore
import Testing

/// 弹幕来源的宽容解析（对齐上游 `Danmaku.arrayFrom`）。
///
/// 这些形状不是「随便加的」：各家弹幕接口返回的 JSON 千奇百怪，少认一种，用户就少一个可用的源 ——
/// 而现象只是「弹幕搜不到」，很难查。
@Suite("弹幕来源解析")
struct DanmakuSourceTests {
    @Test("JSON 数组：逐项取 name / url / source（含别名）")
    func jsonArray() {
        let body = """
        [{"name":"A站","url":"https://a.example.com/1.xml","source":"a"},
         {"name":"B站","url":"https://b.example.com/2.xml","from":"b"}]
        """

        let items = DanmakuSource.array(from: body)

        #expect(items.count == 2)
        #expect(items[0].displayName == "A站")
        #expect(items[0].url == "https://a.example.com/1.xml")
        #expect(items[0].source == "a")
        #expect(items[1].source == "b")
    }

    @Test("嵌套键：`data` / `list` / `result` / `items` … 里是数组就取它")
    func nestedKeys() {
        #expect(DanmakuSource.array(from: #"{"data":[{"url":"https://a/1.xml"}]}"#).count == 1)
        #expect(DanmakuSource.array(from: #"{"list":[{"url":"https://a/1.xml"}]}"#).count == 1)
        #expect(DanmakuSource.array(from: #"{"results":{"items":[{"url":"https://a/1.xml"}]}}"#).count == 1)
    }

    @Test("裸字符串：当一条来源，url 就是它自己")
    func bareString() {
        let items = DanmakuSource.array(from: "https://a.example.com/1.xml")

        #expect(items.count == 1)
        #expect(items[0].url == "https://a.example.com/1.xml")
        #expect(items[0].name == "https://a.example.com/1.xml")
    }

    @Test("字符串里含 JSON（`[` / `{` 开头）再解一次")
    func stringifyJSON() {
        let items = DanmakuSource.array(from: #"[{"url":"https://a/1.xml"}]"#)

        #expect(items.count == 1)
        #expect(items[0].url == "https://a/1.xml")
    }

    @Test("单对象也认；没有 url 的项一律丢掉")
    func singleObjectAndFilter() {
        #expect(DanmakuSource.array(from: #"{"url":"https://a/1.xml"}"#).count == 1)
        #expect(DanmakuSource.array(from: #"[{"name":"没有地址"},{"url":""},{"url":"https://a/1.xml"}]"#).count == 1)
    }

    @Test("空响应 / 认不出来的内容：不崩，能给的给出来")
    func degenerateInputs() {
        #expect(DanmakuSource.array(from: "").isEmpty)
        #expect(DanmakuSource.array(from: "   ").isEmpty)
        #expect(DanmakuSource.array(from: "不是 JSON 也不是地址").count == 1)
    }
}

/// 弹幕行与弹幕文件解析（对齐上游 `DanmakuData` 的字段判法与 `p` 串格式）。
@Suite("弹幕行与弹幕文件")
struct DanmakuLineTests {
    @Test("参数串：时间 / 类型 / 字号 / 颜色；颜色强制补成不透明")
    func parsesParams() throws {
        let line = try #require(DanmakuLine(params: "1.5,1,25,16711680", text: "你好"))

        #expect(line.time == 1.5)
        #expect(line.type == 1)
        #expect(line.size == 25)
        #expect(line.color == 0xFFFF_0000)
        #expect(line.text == "你好")
        #expect(line.isScroll)
    }

    @Test("描边：颜色数值不大于纯黑用白，否则用黑（照抄上游那条粗判法）")
    func shadowRule() throws {
        let dark = try #require(DanmakuLine(params: "0,1,25,0", text: "黑"))
        let light = try #require(DanmakuLine(params: "0,1,25,16777215", text: "白"))

        #expect(dark.shadowColor == 0xFFFF_FFFF)
        #expect(light.shadowColor == 0xFF00_0000)
    }

    @Test("顶部 / 底部：type 5 / 4，其余按滚动")
    func positionTypes() throws {
        let top = try #require(DanmakuLine(params: "0,5,25,0", text: "顶"))
        let bottom = try #require(DanmakuLine(params: "0,4,25,0", text: "底"))
        let scrolling = try #require(DanmakuLine(params: "0,3,25,0", text: "滚"))

        #expect(top.isTop)
        #expect(bottom.isBottom)
        #expect(scrolling.isScroll)
    }

    @Test("文本反转义四种实体")
    func unescapesEntities() throws {
        let line = try #require(DanmakuLine(params: "0,1,25,0", text: "a&amp;b &quot;c&quot; &gt; &lt;"))

        #expect(line.text == "a&b \"c\" > <")
    }

    @Test("坏行返回 nil（字段不足 / 时间不是数字）—— 不让一行毁掉整份文件")
    func badRowsAreRejected() {
        #expect(DanmakuLine(params: "0,1,25", text: "缺颜色") == nil)
        #expect(DanmakuLine(params: "abc,1,25,0", text: "时间不是数字") == nil)
    }

    @Test("文件解析：按时间排序、坏行跳过、末尾截断也尽量把已解析的给出来")
    func documentParsing() {
        let xml = """
        <?xml version="1.0"?>
        <i><d p="3.0,1,25,16777215">晚的</d><d p="1.0,5,25,0">早的</d>\
        <d p="坏的">跳过</d><d p="2.0,4,25,0">中间的</d></i>
        """

        let lines = DanmakuDocument.parse(xml)

        #expect(lines.map(\.text) == ["早的", "中间的", "晚的"])
        #expect(lines.map(\.time) == [1.0, 2.0, 3.0])

        // 末尾被截断：前面的照收
        let truncated = DanmakuDocument.parse("""<i><d p="1.0, 1, 25, 0">好的</d><d p="2.0, 1, 25, 0">截断""")
        #expect(truncated.map(\.text) == ["好的"])
    }

    @Test("自闭合 `<d p=\"…\"/>` 跳过（没有文本）")
    func selfClosingSkipped() {
        #expect(DanmakuDocument.parse(#"<i><d p="1.0,1,25,0"/></i>"#).isEmpty)
    }
}
