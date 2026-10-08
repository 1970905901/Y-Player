import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("直播 EPG 地址覆盖与历史（M07d-1）")
struct LiveEPGSettingTests {
    @Test("默认：没有覆盖、没有历史；空存档也是默认")
    func defaults() {
        let setting = LiveEPGSetting()
        #expect(!setting.isActive)
        #expect(setting.history.isEmpty)
        #expect(LiveEPGSetting.decode(nil) == setting)
        #expect(LiveEPGSetting.decode("").url.isEmpty)
    }

    @Test("换地址：去首尾空白、记进历史（最近在最前、去重、封顶 20）")
    func usingAddress() {
        var setting = LiveEPGSetting().using("  http://a/epg.php  ")
        #expect(setting.url == "http://a/epg.php")
        #expect(setting.isActive)
        #expect(setting.history == ["http://a/epg.php"])

        setting = setting.using("http://b/epg.php")
        #expect(setting.history == ["http://b/epg.php", "http://a/epg.php"])

        // 再用回 a：提到最前，不会出现两条。
        setting = setting.using("http://a/epg.php")
        #expect(setting.history == ["http://a/epg.php", "http://b/epg.php"])

        // 封顶：最新的留在最前，最旧的被挤掉。
        var many = LiveEPGSetting()
        for index in 0 ..< (LiveEPGSetting.historyLimit + 5) {
            many = many.using("http://h\(index)/epg.xml")
        }
        #expect(many.history.count == LiveEPGSetting.historyLimit)
        #expect(many.history.first == "http://h\(LiveEPGSetting.historyLimit + 4)/epg.xml")
        #expect(many.history.last == "http://h5/epg.xml")
    }

    @Test("清除覆盖不动历史；删历史里**正在用**的那条会一并清掉覆盖（上游 removeHistory）")
    func clearingAndRemoving() {
        let setting = LiveEPGSetting().using("http://a/epg.php").using("http://b/epg.php")

        let cleared = setting.using("")
        #expect(!cleared.isActive)
        #expect(cleared.history == ["http://b/epg.php", "http://a/epg.php"])

        // 删无关的一条：覆盖不动。
        let removedOther = setting.removing("http://a/epg.php")
        #expect(removedOther.url == "http://b/epg.php")
        #expect(removedOther.history == ["http://b/epg.php"])

        // 删正在用的那条：覆盖一并清掉。
        let removedCurrent = setting.removing("http://b/epg.php")
        #expect(removedCurrent.url.isEmpty)
        #expect(removedCurrent.history == ["http://a/epg.php"])

        // 清空历史不动当前覆盖。
        let clearedHistory = setting.clearingHistory()
        #expect(clearedHistory.url == "http://b/epg.php")
        #expect(clearedHistory.history.isEmpty)

        // 空值：原样返回（不误删）。
        #expect(setting.removing("") == setting)
    }

    @Test("存档：JSON 往返；坏存档当默认；历史里的空白与重复在读存档时被清掉")
    func persistence() {
        let setting = LiveEPGSetting().using("http://a/epg.php")
        #expect(LiveEPGSetting.decode(setting.persistenceValue) == setting)

        #expect(LiveEPGSetting.decode("{不是 JSON").url.isEmpty)
        #expect(LiveEPGSetting.decode("[\"数组不是对象\"]").url.isEmpty)

        let messy = "{\"url\":\" http://a/epg.php \",\"history\":[\"http://a/epg.php\",\"  \",\"http://a/epg.php\",\"http://b/x.xml\"]}"
        let decoded = LiveEPGSetting.decode(messy)
        #expect(decoded.url == "http://a/epg.php")
        #expect(decoded.history == ["http://a/epg.php", "http://b/x.xml"])
    }
}
