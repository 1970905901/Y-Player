import Foundation

/// 一个直播源的 EPG 全集：按「频道 + 日期」切片的节目单 + 频道显示名。
///
/// 上游把这些散在 `EpgParser` 的静态缓存里（`Map<String, Epg>`）；这里做成值类型：
/// ``LiveEPGRepository/load(_:)`` 的返回值就是全部节目单，界面按 ``LiveChannel/epgID`` 取。
///
/// 界面真正要用的取值语义都直接放在这里（免得每个界面各写一遍遍历）：
/// ``currentProgram(key:at:)``（正在播）/ ``nextProgram(key:at:)``（下一档）/ ``displayName(for:fallback:)``
/// （EPG 里的频道名，取不到回落到清单里的名字）/ ``logo(for:fallback:)``（`<icon src>`，同样回落）。
/// XMLTV 常一次给 1~3 天，所以节目查询都**跨切片**找。
public struct EPGGuide: Sendable, Hashable {
    /// 解析时用的直播源时区（``LiveSource/timeZone``；空或非法时退回本机）。
    public var timeZone: TimeZone
    /// `channel id` → `<display-name>`（XMLTV 的 `<channel>` 段）。
    public var channelNames: [String: String]
    /// `channel id` → `<icon src="…">`（XMLTV 的 `<channel>` 段）。
    ///
    /// 上游 `EpgParser.bindResultsToLive` 用它做**频道图标回填**：清单里没写 `logo` 的频道，
    /// 用节目单文件里的图标（见 M07c）。
    public var channelLogos: [String: String]
    /// 节目单切片（`key + "@" + date` 唯一）。
    public var schedules: [EPGSchedule]

    public init(
        timeZone: TimeZone = .current,
        channelNames: [String: String] = [:],
        channelLogos: [String: String] = [:],
        schedules: [EPGSchedule] = []
    ) {
        self.timeZone = timeZone
        self.channelNames = channelNames
        self.channelLogos = channelLogos
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

    /// 频道图标：XMLTV 里有 `<icon src>` 就用它，否则回落到传入的地址（清单里的 `logo`）。
    public func logo(for key: String, fallback: String = "") -> String {
        let logo = EPGGuide.trimmed(channelLogos[key])
        return logo.isEmpty ? fallback : logo
    }

    /// 这个频道这一天是不是已经有节目单了 —— x-tvg 接口形态据此**跳过重复请求**
    /// （上游 `LiveApi.fetchEpgDay` 的 `noneMatch(epg -> epg.equal(date))`）。
    public func contains(key: String, date: String) -> Bool {
        schedules.contains { $0.key == key && $0.date == date }
    }

    /// 把切片键统一改写成 `key`，并丢掉 XMLTV 自己的频道名/图标（x-tvg 接口形态用，M07c）。
    ///
    /// 上游接口形态拿到的 `Epg` 只挂 `key`（直播频道的 `epgID`）和日期，没有频道名；
    /// 同一天的多条切片并成一条，并按「同一开始时间的节目去重」收尾（与 ``merging(_:)`` 同一套比较键）。
    public func rekeyed(to key: String) -> EPGGuide {
        guard !key.isEmpty else {
            return self
        }
        var slices: [EPGSchedule] = []
        var indexByDate: [String: Int] = [:]
        for schedule in schedules {
            if let index = indexByDate[schedule.date] {
                slices[index].programs.append(contentsOf: schedule.programs)
            } else {
                indexByDate[schedule.date] = slices.count
                slices.append(EPGSchedule(key: key, date: schedule.date, programs: schedule.programs))
            }
        }
        for index in slices.indices {
            slices[index].programs.sort { ($0.startTime, $0.title) < ($1.startTime, $1.title) }
            var ids = Set<String>()
            slices[index].programs = slices[index].programs.filter { ids.insert($0.id).inserted }
        }
        return EPGGuide(timeZone: timeZone, schedules: slices)
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
        // 图标同理：只补空缺，不覆盖已经拿到的。
        for (key, logo) in other.channelLogos {
            let existing = EPGGuide.trimmed(merged.channelLogos[key])
            let incoming = EPGGuide.trimmed(logo)
            if existing.isEmpty, !incoming.isEmpty {
                merged.channelLogos[key] = logo
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
