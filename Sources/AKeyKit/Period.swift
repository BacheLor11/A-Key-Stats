import Foundation

// MARK: - 统计周期
//
// 概览页可以按「今天 / 本月 / 今年 / 有史以来」看同一套指标。
// 天数据是逐日 JSON 存在盘上的，跨周期就是把它们加在一起 ——
// 键次数相加、点击相加、热力网格逐格相加、峰面积取最大。

public enum StatsPeriod: String, CaseIterable, Identifiable, Codable {
    case today
    case month
    case year
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: return "今天"
        case .month: return "本月"
        case .year: return "今年"
        case .all: return "全部"
        }
    }

    public var englishTitle: String {
        switch self {
        case .today: return "Today"
        case .month: return "This Month"
        case .year: return "This Year"
        case .all: return "All Time"
        }
    }

    /// 这一天属不属于本周期（`today` 是 yyyy-MM-dd）
    public func contains(day key: String, today: String) -> Bool {
        switch self {
        case .today: return key == today
        case .month: return key.hasPrefix(String(today.prefix(7)))   // yyyy-MM
        case .year: return key.hasPrefix(String(today.prefix(4)))    // yyyy
        case .all: return true
        }
    }
}

// MARK: - 聚合结果

public struct PeriodStats: Equatable {
    public var keys: [String: Int] = [:]
    public var hourly: [Int] = [Int](repeating: 0, count: 24)
    public var clicks = ClickStats()
    public var padGrid = HeatGrid()
    public var mouseGrid = HeatGrid()
    public var padTravel: Double = 0
    public var mouseTravel: Double = 0
    public var padContacts = 0
    public var mouseContacts = 0
    public var padMaxContact: Double = 0
    public var activeSeconds = 0
    /// 有活动的天数（空白天不计数，否则「日均」会被稀释）
    public var dayCount = 0
    public var firstDay: String?
    public var lastDay: String?

    public init() {}

    public var keyTotal: Int { keys.values.reduce(0, +) }
    public var clickTotal: Int { clicks.total }
    public var isEmpty: Bool { dayCount == 0 }

    public var padTravelCentimeters: Double { padTravel * 20.0 }
    public var mouseTravelCentimeters: Double { mouseTravel * 20.0 }

    /// 日均按键
    public var dailyKeyAverage: Int {
        dayCount > 0 ? keyTotal / dayCount : 0
    }

    public mutating func add(_ day: DayStats) {
        // 完全空白的一天不算进分母
        let hasActivity = day.keyTotal > 0 || day.clickTotal > 0 || day.padContacts > 0
            || day.mouseContacts > 0 || day.activeSeconds > 0
            || day.clicks.scroll > 0 || day.clicks.padScroll > 0
        guard hasActivity else { return }

        dayCount += 1
        if firstDay == nil || day.date < firstDay! { firstDay = day.date }
        if lastDay == nil || day.date > lastDay! { lastDay = day.date }

        for (code, count) in day.keys { keys[code, default: 0] += count }
        if day.hourly.count == 24 {
            for hour in 0..<24 { hourly[hour] += day.hourly[hour] }
        }

        clicks.left += day.clicks.left
        clicks.right += day.clicks.right
        clicks.middle += day.clicks.middle
        clicks.scroll += day.clicks.scroll
        clicks.padScroll += day.clicks.padScroll

        padGrid.merge(day.padGrid)
        mouseGrid.merge(day.mouseGrid)
        padTravel += day.padTravel
        mouseTravel += day.mouseTravel
        padContacts += day.padContacts
        mouseContacts += day.mouseContacts
        padMaxContact = max(padMaxContact, day.padMaxContact)
        activeSeconds += day.activeSeconds
    }

    /// 调试／演示用：把当前聚合按倍数放大（不动真实数据）
    public func scaled(by factor: Int, days: Int) -> PeriodStats {
        guard factor > 1 else { return self }
        var out = self
        for (code, count) in keys { out.keys[code] = count * factor }
        for hour in 0..<24 { out.hourly[hour] = hourly[hour] * factor }
        out.clicks.left = clicks.left * factor
        out.clicks.right = clicks.right * factor
        out.clicks.middle = clicks.middle * factor
        out.clicks.scroll = clicks.scroll * factor
        out.clicks.padScroll = clicks.padScroll * factor
        out.padTravel = padTravel * Double(factor)
        out.mouseTravel = mouseTravel * Double(factor)
        out.padContacts = padContacts * factor
        out.mouseContacts = mouseContacts * factor
        out.activeSeconds = activeSeconds * factor
        out.dayCount = max(dayCount * factor, days)
        return out
    }
}
