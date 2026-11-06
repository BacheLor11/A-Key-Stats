import Foundation

public final class Store {
    public static let shared = Store()

    public let root: URL
    private let daysDir: URL
    private let trajDir: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/A-Key-Stats", isDirectory: true)
        self.root = base
        daysDir = base.appendingPathComponent("days", isDirectory: true)
        trajDir = base.appendingPathComponent("traj", isDirectory: true)
        try? FileManager.default.createDirectory(at: daysDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: trajDir, withIntermediateDirectories: true)
    }

    // MARK: 天

    private func dayURL(_ key: String) -> URL {
        daysDir.appendingPathComponent("\(key).json")
    }

    public func load(day key: String) -> DayStats? {
        guard let data = try? Data(contentsOf: dayURL(key)) else { return nil }
        return try? JSONDecoder().decode(DayStats.self, from: data)
    }

    public func save(_ stats: DayStats) {
        guard let data = try? encoder.encode(stats) else { return }
        try? data.write(to: dayURL(stats.date), options: .atomic)
    }

    public func availableDays() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: daysDir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted(by: >)
    }

    public func loadAll() -> [DayStats] {
        availableDays().compactMap { load(day: $0) }
    }

    /// 最近 N 天（缺失的日期补空，方便画柱状图）
    public func recent(_ count: Int, endingAt date: Date = Date()) -> [DayStats] {
        var result: [DayStats] = []
        let cal = Calendar.current
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: date) else { continue }
            let key = DayKey.of(d)
            result.append(load(day: key) ?? DayStats(date: key))
        }
        return result
    }

    // MARK: 轨迹

    public func trajectoryURL(day key: String, kind: TrajKind) -> URL {
        trajDir.appendingPathComponent("\(key).\(kind.rawValue).bin")
    }

    public func trajectory(day key: String, kind: TrajKind, limit: Int = 120_000) -> [TrajPoint] {
        TrajectoryWriter.read(url: trajectoryURL(day: key, kind: kind), limit: limit)
    }

    public func trajectorySize(day key: String) -> Int {
        var total = 0
        for kind in TrajKind.allCases {
            let path = trajectoryURL(day: key, kind: kind).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int { total += size }
        }
        return total
    }

    // MARK: 维护

    /// 早期版本把 HID usage 直接当成虚拟键码存了，这里一次性把历史数据换算过来。
    /// 换算后同一天里会有多个 usage 落到同一个键上（欧版回车、左右 shift 别名等），按次数相加。
    /// 返回被改写的天数。
    @discardableResult
    public func migrateKeycodesIfNeeded() -> Int {
        let marker = root.appendingPathComponent(".keycodes-v2")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return 0 }
        var touched = 0
        for key in availableDays() {
            guard var day = load(day: key), !day.keys.isEmpty else { continue }
            var remapped: [String: Int] = [:]
            for (raw, count) in day.keys {
                let usage = UInt16(raw) ?? 0
                let vk = HIDKeymap.virtualKey(for: usage) ?? usage
                remapped[String(vk), default: 0] += count
            }
            guard remapped != day.keys else { continue }
            day.keys = remapped
            save(day)
            touched += 1
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        return touched
    }

    public func resetAll() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: daysDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        for url in (try? fm.contentsOfDirectory(at: trajDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    public func exportCSV(to url: URL) throws {
        var lines = ["date,keyCode,keyName,count,hourlyPeak,leftClick,rightClick,scroll,padContacts,padTravel,padMaxContact,activeSeconds"]
        for day in loadAll() {
            let peak = day.hourly.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
            if day.keys.isEmpty {
                lines.append("\(day.date),,,,,\(day.clicks.left),\(day.clicks.right),\(day.clicks.scroll),\(day.padContacts),\(String(format: "%.2f", day.padTravel)),\(String(format: "%.3f", day.padMaxContact)),\(day.activeSeconds)")
            }
            for (code, count) in day.keys.sorted(by: { $0.value > $1.value }) {
                lines.append("\(day.date),\(code),,\(count),\(peak),\(day.clicks.left),\(day.clicks.right),\(day.clicks.scroll),\(day.padContacts),\(String(format: "%.2f", day.padTravel)),\(String(format: "%.3f", day.padMaxContact)),\(day.activeSeconds)")
            }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
