import Foundation

/// 一个直播源的 EPG 全集：按「频道 + 日期」切片的节目单 + 频道显示名。
///
/// 上游把这些散在 `EpgParser` 的静态缓存里（`Map<String, Epg>`）；这里做成值类型：
/// ``LiveEPGRepository/load(_:)`` 的返回值就是全部节目单，界面按 ``LiveChannel/epgID`` 取。
///
/// 三个取值语义是界面真正要用的，所以直接放在这里（免得每个界面各写一遍遍历）：
/// ``currentProgram(key:at:)``（正在播）/ ``nextProgram(key:at:)``（下一档）/ ``displayName(for:fallback:)``
/// （EPG 里的频道名，取不到回落到清单里的名字）。XMLTV 常一次给 1~3 天，所以这三个查询都**跨切片**找。
public struct EPGGuide: Sendable, Hashable {
    /// 解析时用的直播源时区（``LiveSource/timeZone``；空或非法时退回本机）。
    public var timeZone: TimeZone
    /// `channel id` → `<display-name>`（XMLTV 的 `<channel>` 段）。
    public var channelNames: [String: String]
    /// 节目单切片（`key + "@" + date` 唯一）。
    public var schedules: [EPGSchedule]

    public init(
        timeZone: TimeZone = .current,
        channelNames: [String: String] = [:],
        schedules: [EPGSchedule] = []
    ) {
        self.timeZone = timeZone
        self.channelNames = channelNames
        self.schedules = schedules
    }

    /// 一条节目都没有（调用方据此说「这个源没有节目单」）。
    public var isEmpty: Bool {
        schedules.isEmpty
    }

    /// 某频道某天的节目单（没有则 `nil`）。
    public func schedule(key: String, date: String) -> EPGSchedule? {
        schedules.first { $0.key == key && $0.date == date }
    }

    /// 某频道「正在播」的节目：跨切片找。
    public func currentProgram(key: String, at now: Date = Date()) -> EPGProgram? {
        for schedule in schedules where schedule.key == key {
            if let program = schedule.currentProgram(at: now) {
                return program
            }
        }
        return nil
    }

    /// 某频道「下一档」节目：跨切片找（当天已播完会落到下一天）。
    public func nextProgram(key: String, at now: Date = Date()) -> EPGProgram? {
        for schedule in schedules where schedule.key == key {
            if let program = schedule.nextProgram(at: now) {
                return program
            }
        }
        return nil
    }

    /// 频道显示名：XMLTV 里有 `<display-name>` 就用它，否则回落到传入的名字（清单里的频道名）。
    public func displayName(for key: String, fallback: String = "") -> String {
        let name = EPGGuide.trimmed(channelNames[key])
        return name.isEmpty ? fallback : name
    }

    /// 合并另一份指南：**切片（频道 + 日期）内按节目去重**（同 `start-end-title` 只留先到的），合并后重排。
    ///
    /// 一个直播源可以配多个 EPG 地址（例如「央视.xml,卫视.xml.gz」），逐个拉完后用这个方法并起来；
    /// 两个文件都覆盖同一频道同一天时**不会互相顶掉**，而是把节目拼在同一份切片里。
    public func merging(_ other: EPGGuide) -> EPGGuide {
        var merged = self
        // 频道名只补空缺：先到的更贴近这个直播源的清单。
        for (key, name) in other.channelNames {
            let existing = EPGGuide.trimmed(merged.channelNames[key])
            let incoming = EPGGuide.trimmed(name)
            if existing.isEmpty, !incoming.isEmpty {
                merged.channelNames[key] = name
            }
        }
        var indexByID: [String: Int] = [:]
        for (index, schedule) in merged.schedules.enumerated() {
            indexByID[schedule.id] = index
        }
        for schedule in other.schedules {
            guard let index = indexByID[schedule.id] else {
                indexByID[schedule.id] = merged.schedules.count
                merged.schedules.append(schedule)
                continue
            }
            var existing = merged.schedules[index]
            var ids = Set(existing.programs.map { $0.id })
            for program in schedule.programs where ids.insert(program.id).inserted {
                existing.programs.append(program)
            }
            // 两条时间线拼在一起就不再有序，重排（与 `EPGXMLTVParser` 同一套比较键）。
            existing.programs.sort { ($0.startTime, $0.title) < ($1.startTime, $1.title) }
            merged.schedules[index] = existing
        }
        return merged
    }

    /// 去首尾空白（`<display-name>` 里常见换行与缩进）。
    static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
