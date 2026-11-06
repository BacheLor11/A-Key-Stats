import Foundation

// MARK: - 原始轨迹（降采样后按天追加）

public struct TrajPoint: Equatable {
    public var t: Float      // 当天 00:00 起的秒数
    public var x: Float      // 0..1
    public var y: Float      // 0..1
    /// 触控板上的接触点 id；鼠标表面恒为 0。渲染时按 id 分组成不同折线，
    /// 否则双指滚动时两点交替出现，连线会拉成一整片 Z 字。
    public var id: UInt16

    public init(t: Float, x: Float, y: Float, id: UInt16 = 0) {
        self.t = t; self.x = x; self.y = y; self.id = id
    }
}

public enum TrajKind: String, CaseIterable {
    case pad
    case mouse
}

/// 二进制追加，两种记录格式：
/// v1: header(8B) + (Float32 t, UInt16 x, UInt16 y) = 8B/点
/// v2: header(8B) + (Float32 t, UInt16 x, UInt16 y, UInt16 id) = 10B/点
/// 读到 v1 文件会自动升级成 v2（旧点 id 记为 0）。
public final class TrajectoryWriter {
    static let headerSize = 8
    static let recordV1 = 8
    static let recordV2 = 10

    private let url: URL
    private var handle: FileHandle?
    private var lastByID: [UInt16: TrajPoint] = [:]
    private var buffer = Data()
    private let flushThreshold = 4096

    public private(set) var appended = 0

    public init(url: URL) {
        self.url = url
    }

    private func makeHeader() -> Data {
        var header = Data()
        header.append(contentsOf: [0x41, 0x4B, 0x53, 0x54])   // AKST
        header.append(contentsOf: [0x02, 0x00])              // version 2
        header.append(contentsOf: [0x00, 0x00])              // reserved
        return header
    }

    private func ensureHandle() {
        guard handle == nil else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: makeHeader())
        } else if Self.version(of: url) == 1 {
            // 旧格式原地升级，别把今天的轨迹丢掉
            let old = Self.readV1(url: url)
            var data = makeHeader()
            for p in old { data.append(Self.record(t: p.t, x: p.x, y: p.y, id: 0)) }
            try? data.write(to: url)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private static func version(of url: URL) -> Int {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 2 }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: headerSize)
        guard head.count >= 6, head[0] == 0x41, head[1] == 0x4B else { return 2 }
        return Int(head[4])
    }

    private static func record(t: Float, x: Float, y: Float, id: UInt16) -> Data {
        var data = Data(capacity: recordV2)
        withUnsafeBytes(of: t.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        let xi = UInt16(max(0, min(65535, x * 65535)))
        let yi = UInt16(max(0, min(65535, y * 65535)))
        withUnsafeBytes(of: xi.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: yi.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: id.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// 降采样规则：同一根手指、位移太小且间隔太短的点直接丢掉，避免高频重复点撑爆文件
    public func append(t: Float, x: Float, y: Float, id: UInt16 = 0) {
        if let last = lastByID[id] {
            let dt = t - last.t
            let dx = x - last.x, dy = y - last.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dt < 0.05 && dist < 0.002 { return }
            if dt < 0 { return }
        }
        ensureHandle()
        buffer.append(Self.record(t: t, x: x, y: y, id: id))
        lastByID[id] = TrajPoint(t: t, x: x, y: y, id: id)
        appended += 1
        if buffer.count >= flushThreshold { flush() }
    }

    public func flush() {
        guard !buffer.isEmpty, let handle else { return }
        do {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            // 写失败就丢掉这一批，不让采集线程卡住
            buffer.removeAll(keepingCapacity: true)
        }
    }

    public func close() {
        flush()
        try? handle?.close()
        handle = nil
    }

    // MARK: 读

    public static func read(url: URL, limit: Int = 200_000) -> [TrajPoint] {
        guard let data = try? Data(contentsOf: url), data.count > headerSize else { return [] }
        let ver = Int(data[4])
        if ver == 1 { return decodeV1(data: data, limit: limit) }
        var points: [TrajPoint] = []
        points.reserveCapacity(min(limit, data.count / recordV2))
        var index = headerSize
        while index + recordV2 <= data.count && points.count < limit {
            points.append(data.withUnsafeBytes { raw -> TrajPoint in
                let t = raw.loadUnaligned(fromByteOffset: index, as: UInt32.self)
                let x = raw.loadUnaligned(fromByteOffset: index + 4, as: UInt16.self)
                let y = raw.loadUnaligned(fromByteOffset: index + 6, as: UInt16.self)
                let id = raw.loadUnaligned(fromByteOffset: index + 8, as: UInt16.self)
                return TrajPoint(t: Float(bitPattern: UInt32(littleEndian: t)),
                                 x: Float(UInt16(littleEndian: x)) / 65535,
                                 y: Float(UInt16(littleEndian: y)) / 65535,
                                 id: UInt16(littleEndian: id))
            })
            index += recordV2
        }
        return points
    }

    private static func readV1(url: URL) -> [TrajPoint] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decodeV1(data: data, limit: 400_000)
    }

    private static func decodeV1(data: Data, limit: Int) -> [TrajPoint] {
        var points: [TrajPoint] = []
        var index = headerSize
        while index + recordV1 <= data.count && points.count < limit {
            points.append(data.withUnsafeBytes { raw -> TrajPoint in
                let t = raw.loadUnaligned(fromByteOffset: index, as: UInt32.self)
                let x = raw.loadUnaligned(fromByteOffset: index + 4, as: UInt16.self)
                let y = raw.loadUnaligned(fromByteOffset: index + 6, as: UInt16.self)
                return TrajPoint(t: Float(bitPattern: UInt32(littleEndian: t)),
                                 x: Float(UInt16(littleEndian: x)) / 65535,
                                 y: Float(UInt16(littleEndian: y)) / 65535,
                                 id: 0)
            })
            index += recordV1
        }
        return points
    }
}
