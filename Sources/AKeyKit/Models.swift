import Foundation

// MARK: - 点击

public struct ClickStats: Codable, Equatable {
    public var left = 0
    public var right = 0
    public var middle = 0
    /// 真正的滚轮（离散刻度，一般来自传统鼠标）
    public var scroll = 0
    /// 触控板双指滚动：以前被错算进 scroll，现在单独记
    public var padScroll = 0

    public init() {}

    public var total: Int { left + right + middle }

    // 老数据没有 padScroll 字段，缺了就当 0，不能整份崩掉
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decodeIfPresent(Int.self, forKey: .left) ?? 0
        right = try c.decodeIfPresent(Int.self, forKey: .right) ?? 0
        middle = try c.decodeIfPresent(Int.self, forKey: .middle) ?? 0
        scroll = try c.decodeIfPresent(Int.self, forKey: .scroll) ?? 0
        padScroll = try c.decodeIfPresent(Int.self, forKey: .padScroll) ?? 0
    }
}

// MARK: - 热力网格

/// 归一化坐标落桶。触控板与鼠标表面各一份，同尺寸便于共用渲染。
public struct HeatGrid: Codable, Equatable {
    public static let cols = 32
    public static let rows = 24
    public static let cellCount = cols * rows

    /// 每格停留帧数（≈ 停留时间），UInt32 足够（约 4 年 60Hz 连续使用）
    public var cells: [UInt32]
    public var total: UInt32

    public init() {
        cells = [UInt32](repeating: 0, count: HeatGrid.cellCount)
        total = 0
    }

    public var maxCell: UInt32 { cells.max() ?? 0 }

    public mutating func add(x: Double, y: Double, weight: UInt32 = 1) {
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return }
        let c = min(HeatGrid.cols - 1, max(0, Int(x * Double(HeatGrid.cols))))
        let r = min(HeatGrid.rows - 1, max(0, Int(y * Double(HeatGrid.rows))))
        let index = r * HeatGrid.cols + c
        cells[index] &+= weight
        total &+= weight
    }

    public func cell(row: Int, col: Int) -> UInt32 {
        guard row >= 0, row < HeatGrid.rows, col >= 0, col < HeatGrid.cols else { return 0 }
        return cells[row * HeatGrid.cols + col]
    }

    public mutating func merge(_ other: HeatGrid) {
        guard other.cells.count == cells.count else { return }
        for i in 0..<cells.count { cells[i] &+= other.cells[i] }
        total &+= other.total
    }
}

// MARK: - 一天的统计

public struct DayStats: Codable, Equatable {
    public var date: String                    // yyyy-MM-dd
    public var keys: [String: Int]             // keyCode 字符串 -> 次数
    public var hourly: [Int]                   // 24 段，按键次数
    public var clicks: ClickStats
    public var padGrid: HeatGrid
    public var mouseGrid: HeatGrid
    public var padTravel: Double               // 轨迹累计里程（归一化单位）
    public var mouseTravel: Double
    public var padContacts: Int                // 接触帧数
    public var mouseContacts: Int
    public var padMaxContact: Double           // 接触面积峰值
    public var activeSeconds: Int
    /// 外设信号（只存计数，见 HardwareWatch）。老文件里没有这一段。
    public var hardware: HardwareDay

    public init(date: String) {
        self.date = date
        keys = [:]
        hourly = [Int](repeating: 0, count: 24)
        clicks = ClickStats()
        padGrid = HeatGrid()
        mouseGrid = HeatGrid()
        padTravel = 0
        mouseTravel = 0
        padContacts = 0
        mouseContacts = 0
        padMaxContact = 0
        activeSeconds = 0
        hardware = HardwareDay()
    }

    enum CodingKeys: String, CodingKey {
        case date, keys, hourly, clicks, padGrid, mouseGrid
        case padTravel, mouseTravel, padContacts, mouseContacts, padMaxContact
        case activeSeconds, hardware
    }

    /// 手写解码：0.5.0 之前的数据文件里没有 hardware，缺字段不能让整份数据崩掉。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        keys = try c.decodeIfPresent([String: Int].self, forKey: .keys) ?? [:]
        var hours = try c.decodeIfPresent([Int].self, forKey: .hourly) ?? []
        if hours.count < 24 { hours += [Int](repeating: 0, count: 24 - hours.count) }
        hourly = Array(hours.prefix(24))
        clicks = try c.decodeIfPresent(ClickStats.self, forKey: .clicks) ?? ClickStats()
        padGrid = try c.decodeIfPresent(HeatGrid.self, forKey: .padGrid) ?? HeatGrid()
        mouseGrid = try c.decodeIfPresent(HeatGrid.self, forKey: .mouseGrid) ?? HeatGrid()
        padTravel = try c.decodeIfPresent(Double.self, forKey: .padTravel) ?? 0
        mouseTravel = try c.decodeIfPresent(Double.self, forKey: .mouseTravel) ?? 0
        padContacts = try c.decodeIfPresent(Int.self, forKey: .padContacts) ?? 0
        mouseContacts = try c.decodeIfPresent(Int.self, forKey: .mouseContacts) ?? 0
        padMaxContact = try c.decodeIfPresent(Double.self, forKey: .padMaxContact) ?? 0
        activeSeconds = try c.decodeIfPresent(Int.self, forKey: .activeSeconds) ?? 0
        hardware = try c.decodeIfPresent(HardwareDay.self, forKey: .hardware) ?? HardwareDay()
    }

    public var keyTotal: Int { keys.values.reduce(0, +) }
    public var clickTotal: Int { clicks.total }
}

// MARK: - 日期

public enum DayKey {
    public static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func of(_ date: Date) -> String { formatter.string(from: date) }
    public static func date(from key: String) -> Date? { formatter.date(from: key) }
    public static func hour(of date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }
}
