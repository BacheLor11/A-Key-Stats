import Foundation

// MARK: - 轨迹导出
//
// 盘上的轨迹是 10 字节一个点的二进制（AKST），直接给用户没用，
// 导成 CSV 才能丢进 Excel / pandas / 任何画图工具。
//
// 全部历史可能几百万个点，所以是流式读写：分块解码、攒够 256KB 就落盘，
// 内存峰值跟数据量无关。
public enum TrajectoryExport {

    public enum Scope: String, CaseIterable, Identifiable {
        case today
        case last7
        case all

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .today: return "导出今天"
            case .last7: return "导出最近 7 天"
            case .all: return "导出全部历史"
            }
        }

        public var fileTag: String {
            switch self {
            case .today: return "今天"
            case .last7: return "近7天"
            case .all: return "全部"
            }
        }
    }

    public struct Outcome: Sendable {
        public let url: URL
        public let points: Int
        public let days: Int
        public let bytes: Int
    }

    public enum Failure: LocalizedError {
        case noTrajectory
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .noTrajectory: return "这段时间还没有轨迹数据"
            case .cannotWrite(let path): return "写不进 \(path)"
            }
        }
    }

    /// 要导出哪些日期。只挑真的存在轨迹文件的天 —— 空白天导出来只有表头，
    /// 反而让人以为数据丢了。调用方负责在导出前把采集缓冲 flush 到盘上。
    public static func dates(for scope: Scope, today: String) -> [String] {
        let available = Set(Store.shared.trajectoryDays(kind: .pad))
        switch scope {
        case .today:
            return [today]
        case .last7:
            guard let end = DayKey.date(from: today) else { return [today] }
            var list: [String] = []
            for offset in stride(from: 6, through: 0, by: -1) {
                guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: end) else { continue }
                let key = DayKey.of(day)
                if available.contains(key) { list.append(key) }
            }
            return list.isEmpty ? [today] : list
        case .all:
            let list = available.sorted()
            return list.isEmpty ? [today] : list
        }
    }

    /// CSV 列：date,time,t,x,y,finger
    /// · time 是当天时钟（HH:MM:SS.mmm），t 是当天 0 点起的秒数（浮点）
    /// · x / y 是 0–1 归一化坐标（已经按设置里的 Y 翻转口径处理过）
    /// · finger 是接触点 id，按下与抬起的间隔靠它切成不同手指的线
    @discardableResult
    public static func writeCSV(days: [String], kind: TrajKind, to url: URL) throws -> Outcome {
        let store = Store.shared
        let fm = FileManager.default
        let targets = days
            .map { ($0, store.trajectoryURL(day: $0, kind: kind)) }
            .filter { fm.fileExists(atPath: $0.1.path) }
        guard !targets.isEmpty else { throw Failure.noTrajectory }

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url) else {
            throw Failure.cannotWrite(url.path)
        }
        defer { try? out.close() }

        var buffer = Data()
        var points = 0
        let flushAt = 1 << 18

        func emit(_ text: String) {
            buffer.append(contentsOf: Array(text.utf8))
            if buffer.count >= flushAt {
                try? out.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        emit("date,time,t,x,y,finger\n")

        for (date, fileURL) in targets {
            try forEachPoint(in: fileURL) { point in
                let clock = timeOfDay(point.t)
                emit("\(date),\(clock),\(fixed(point.t, 3)),\(fixed(point.x, 5)),\(fixed(point.y, 5)),\(point.id)\n")
                points += 1
            }
        }

        if !buffer.isEmpty { try? out.write(contentsOf: buffer) }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return Outcome(url: url, points: points, days: targets.count, bytes: bytes)
    }

    // MARK: 流式读

    /// 逐点回调，不把整个文件读进内存。
    /// 兼容 v1（8B/点，无 finger id）与 v2（10B/点）。
    public static func forEachPoint(in url: URL, _ handler: (TrajPoint) -> Void) throws {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        guard let header = try fh.read(upToCount: 8), header.count == 8 else { return }

        let isAKST = header[0] == 0x41 && header[1] == 0x4B && header[2] == 0x53 && header[3] == 0x54
        let version = isAKST ? Int(header[4]) : 2
        let record = version == 1 ? 8 : 10

        var carry = Data()
        var chunk = try fh.read(upToCount: 1 << 18) ?? Data()
        while !chunk.isEmpty {
            var data = Data()
            data.append(carry)
            data.append(chunk)
            let usable = (data.count / record) * record

            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var index = 0
                while index < usable {
                    let t = raw.loadUnaligned(fromByteOffset: index, as: UInt32.self)
                    let x = raw.loadUnaligned(fromByteOffset: index + 4, as: UInt16.self)
                    let y = raw.loadUnaligned(fromByteOffset: index + 6, as: UInt16.self)
                    var id: UInt16 = 0
                    if record == 10 {
                        id = raw.loadUnaligned(fromByteOffset: index + 8, as: UInt16.self)
                    }
                    handler(TrajPoint(t: Float(bitPattern: UInt32(littleEndian: t)),
                                      x: Float(UInt16(littleEndian: x)) / 65535,
                                      y: Float(UInt16(littleEndian: y)) / 65535,
                                      id: UInt16(littleEndian: id)))
                    index += record
                }
            }

            // 半条记录留到下一块，别把点劈成两半
            carry = usable < data.count ? data.subdata(in: usable..<data.count) : Data()
            chunk = try fh.read(upToCount: 1 << 18) ?? Data()
        }
    }

    // MARK: 格式化

    private static func timeOfDay(_ seconds: Float) -> String {
        let total = Double(max(seconds, 0))
        let hour = Int(total) / 3600
        let minute = (Int(total) % 3600) / 60
        let second = total - Double(hour * 3600 + minute * 60)
        return String(format: "%02d:%02d:%06.3f", hour, minute, min(second, 59.999))
    }

    private static func fixed(_ value: Float, _ digits: Int) -> String {
        String(format: "%.\(digits)f", Double(value))
    }
}
