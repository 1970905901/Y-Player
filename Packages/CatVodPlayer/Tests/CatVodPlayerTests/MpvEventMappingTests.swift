@testable import CatVodPlayer
import Testing

/// MPV 事件/属性的**纯映射**。
///
/// 这是「渲染路径未定（第 3 步）」时唯一能先把语义钉住的地方：不需要 libmpv、不需要真机、
/// 不需要终端，映射写错了这里立刻红。
@Suite("MPV 事件映射（纯函数）")
struct MpvEventMappingTests {
    @Test("观察的属性：每个 id 都必须同时有名字和格式")
    func observedProperties() {
        #expect(MpvEventMapping.observedIDs.count == 3)
        #expect(Set(MpvEventMapping.observedIDs).count == 3)
        #expect(MpvEventMapping.propertyName(for: MpvEventMapping.timePositionID) == "time-pos")
        #expect(MpvEventMapping.propertyName(for: MpvEventMapping.durationID) == "duration")
        #expect(MpvEventMapping.propertyName(for: MpvEventMapping.pausedID) == "pause")
        #expect(MpvEventMapping.propertyFormat(for: MpvEventMapping.timePositionID) == "double")
        #expect(MpvEventMapping.propertyFormat(for: MpvEventMapping.durationID) == "double")
        #expect(MpvEventMapping.propertyFormat(for: MpvEventMapping.pausedID) == "flag")
        #expect(MpvEventMapping.propertyName(for: 99) == nil)
        #expect(MpvEventMapping.propertyFormat(for: 99) == nil)
        // 漏一个格式就等于「observe 了但永远收不到值」—— 最难查的那种哑火，所以逐个查
        for id in MpvEventMapping.observedIDs {
            #expect(MpvEventMapping.propertyName(for: id) != nil)
            #expect(MpvEventMapping.propertyFormat(for: id) != nil)
        }
    }

    @Test("time-pos → 位置变化；类型不对或负值一律忽略")
    func timeEffect() {
        let normal = MpvEventMapping.effect(
            ofProperty: MpvEventMapping.timePositionID,
            value: .double(12.5),
            duration: 100
        )
        #expect(normal == .time(current: 12.5, duration: 100))

        // mpv 在某些状态下回 `MPV_FORMAT_NONE`：不能把「没有值」当成「播到 0 秒」
        let empty = MpvEventMapping.effect(
            ofProperty: MpvEventMapping.timePositionID,
            value: .none,
            duration: 100
        )
        #expect(empty == .ignore)

        let wrongType = MpvEventMapping.effect(
            ofProperty: MpvEventMapping.timePositionID,
            value: .string("x"),
            duration: 100
        )
        #expect(wrongType == .ignore)

        let negative = MpvEventMapping.effect(
            ofProperty: MpvEventMapping.timePositionID,
            value: .double(-1),
            duration: 100
        )
        #expect(negative == .ignore)
    }

    @Test("duration → 记时长；pause → 开关；未知 id → 忽略")
    func otherEffects() {
        let duration = MpvEventMapping.effect(
            ofProperty: MpvEventMapping.durationID,
            value: .double(3600),
            duration: 0
        )
        #expect(duration == .duration(3600))

        let paused = MpvEventMapping.effect(
            ofProperty: MpvEventMapping.pausedID,
            value: .flag(true),
            duration: 0
        )
        #expect(paused == .paused(true))
        // flag 在 C 里底层是 int，实现层用整数读也不该崩
        let pausedAsInt = MpvEventMapping.effect(
            ofProperty: MpvEventMapping.pausedID,
            value: .integer(1),
            duration: 0
        )
        #expect(pausedAsInt == .paused(true))

        let unknown = MpvEventMapping.effect(
            ofProperty: 99,
            value: .double(1),
            duration: 0
        )
        #expect(unknown == .ignore)
    }

    @Test("end-file 只有 error 算失败：stop / quit 是我们自己的动作")
    func failureClassification() {
        #expect(MpvEventMapping.isFailure(endFileReason: "error"))
        #expect(!MpvEventMapping.isFailure(endFileReason: "eof"))
        #expect(!MpvEventMapping.isFailure(endFileReason: "stop"))
        #expect(!MpvEventMapping.isFailure(endFileReason: "quit"))
        #expect(!MpvEventMapping.isFailure(endFileReason: "unknown"))
    }

    @Test("属性值取用：数值 / 开关 / 不是那种类型")
    func valueAccessors() {
        #expect(MpvPropertyValue.double(1.5).doubleValue == 1.5)
        #expect(MpvPropertyValue.integer(3).doubleValue == 3)
        #expect(MpvPropertyValue.flag(true).doubleValue == nil)
        #expect(MpvPropertyValue.flag(true).boolValue == true)
        #expect(MpvPropertyValue.flag(false).boolValue == false)
        #expect(MpvPropertyValue.integer(0).boolValue == false)
        #expect(MpvPropertyValue.string("x").boolValue == nil)
        #expect(MpvPropertyValue.none.doubleValue == nil)
        #expect(MpvPropertyValue.none.boolValue == nil)
    }

    @Test("track-list：按类型分三组，封面图轨道不算画面轨")
    func trackListParsing() throws {
        let json = """
        [
            {"id": 1, "type": "video", "default": true},
            {"id": 2, "type": "video", "albumart": true},
            {"id": 3, "type": "audio", "lang": "zh"},
            {"id": 4, "type": "audio", "lang": "en"},
            {"id": 5, "type": "sub", "title": "简体"},
            {"id": 6, "type": "unknown"}
        ]
        """
        let tracks = try #require(MpvEventMapping.trackIDs(fromTrackListJSON: json))
        #expect(tracks.video == [1])
        #expect(tracks.audio == [3, 4])
        #expect(tracks.subtitle == [5])
    }

    @Test("track-list：解析不了返回 nil（别发空列表把界面上的选择清空）")
    func trackListParseFailure() {
        #expect(MpvEventMapping.trackIDs(fromTrackListJSON: "") == nil)
        #expect(MpvEventMapping.trackIDs(fromTrackListJSON: "不是 JSON") == nil)
        #expect(MpvEventMapping.trackIDs(fromTrackListJSON: #"{"a":1}"#) == nil)
        // 空数组是合法输入：就是「没有轨道」。
        #expect(MpvEventMapping.trackIDs(fromTrackListJSON: "[]")?.video == [])
    }

    @Test("事件等待超时：小到不卡命令，大到不空转")
    func waitTimeout() {
        // 这个值直接等于「命令最坏等多久」（事件循环在 actor 里阻塞等待），改大要慎重。
        #expect(MpvEventMapping.eventWaitTimeout > 0)
        #expect(MpvEventMapping.eventWaitTimeout <= 0.2)
    }
}
