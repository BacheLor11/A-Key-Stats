import Foundation

// MARK: - 键盘配列
//
// 坐标系：1 个单位 = 一个标准键宽，原点在左上，y 向下。
// keyCode 用 macOS 的物理键码（IOHID / CGEvent 同一套），跟系统输入法无关。

public struct KeyCap: Identifiable, Equatable {
    public var code: UInt16
    public var label: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public var id: UInt16 { code }
}

public enum KeyboardLayoutID: String, CaseIterable, Identifiable, Codable {
    case ansiCompact
    case ansiFull
    case isoCompact
    case jisCompact

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ansiCompact: return "ANSI 紧凑 · 无数字区"
        case .ansiFull: return "ANSI 全尺寸 · 带数字区"
        case .isoCompact: return "ISO 配列 · 顶部 § 键"
        case .jisCompact: return "JIS 配列 · 日文键盘"
        }
    }

    public var shortName: String {
        switch self {
        case .ansiCompact: return "ANSI 紧凑"
        case .ansiFull: return "ANSI 全尺寸"
        case .isoCompact: return "ISO"
        case .jisCompact: return "JIS"
        }
    }
}

public struct KeyboardLayout {
    public var id: KeyboardLayoutID
    public var keys: [KeyCap]
    public var widthUnits: Double
    public var heightUnits: Double
    private var byCode: [UInt16: KeyCap]

    public func key(_ code: UInt16) -> KeyCap? { byCode[code] }
    public func label(_ code: UInt16) -> String? { byCode[code]?.label }

    init(id: KeyboardLayoutID, keys: [KeyCap], widthUnits: Double, heightUnits: Double) {
        self.id = id
        self.keys = keys
        self.widthUnits = widthUnits
        self.heightUnits = heightUnits
        var map: [UInt16: KeyCap] = [:]
        for key in keys where map[key.code] == nil { map[key.code] = key }
        byCode = map
    }

    public static func build(_ id: KeyboardLayoutID) -> KeyboardLayout {
        var builder = Builder()
        switch id {
        case .ansiCompact: builder.ansi(full: false)
        case .ansiFull: builder.ansi(full: true)
        case .isoCompact: builder.iso()
        case .jisCompact: builder.jis()
        }
        return builder.finish(id)
    }
}

// MARK: - 构造器

private struct Builder {
    var keys: [KeyCap] = []
    var maxWidth: Double = 0

    static let fRow: Double = 0
    static let r1: Double = 1.4
    static let step: Double = 1.0
    static let pad: Double = 0.075      // 键与键之间的缝

    mutating func put(_ code: UInt16, _ label: String, x: Double, y: Double,
                      w: Double = 1, h: Double = 1) {
        keys.append(KeyCap(code: code, label: label,
                           x: x + Self.pad / 2, y: y + Self.pad / 2,
                           w: max(w - Self.pad, 0.18), h: max(h - Self.pad, 0.18)))
        maxWidth = max(maxWidth, x + w)
    }

    @discardableResult
    mutating func row(_ items: [(UInt16, String, Double)], x: Double, y: Double, h: Double = 1) -> Double {
        var cursor = x
        for item in items {
            put(item.0, item.1, x: cursor, y: y, w: item.2, h: h)
            cursor += item.2
        }
        return cursor
    }

    @discardableResult
    mutating func row(_ items: [(UInt16, String)], x: Double, y: Double, h: Double = 1) -> Double {
        row(items.map { ($0.0, $0.1, 1.0) }, x: x, y: y, h: h)
    }

    mutating func finish(_ id: KeyboardLayoutID) -> KeyboardLayout {
        let height = (keys.map { $0.y + $0.h }.max() ?? 1) + 0.08
        return KeyboardLayout(id: id, keys: keys, widthUnits: maxWidth, heightUnits: height)
    }

    // MARK: 共用片段

    private let numberRow: [(UInt16, String)] = [(18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"),
                                                 (22, "6"), (26, "7"), (28, "8"), (25, "9"), (29, "0"),
                                                 (27, "-"), (24, "=")]
    private let qRow: [(UInt16, String)] = [(12, "Q"), (13, "W"), (14, "E"), (15, "R"), (17, "T"),
                                            (16, "Y"), (32, "U"), (34, "I"), (31, "O"), (35, "P"),
                                            (33, "["), (30, "]"), (42, "\\")]
    private let aRow: [(UInt16, String)] = [(0, "A"), (1, "S"), (2, "D"), (3, "F"), (5, "G"),
                                            (4, "H"), (38, "J"), (40, "K"), (37, "L"),
                                            (41, ";"), (39, "'")]
    private let zRow: [(UInt16, String)] = [(6, "Z"), (7, "X"), (8, "C"), (9, "V"), (11, "B"),
                                            (45, "N"), (46, "M"), (43, ","), (47, "."), (44, "/")]
    private let fRowKeys: [(UInt16, String)] = [(122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
                                                (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
                                                (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")]

    private mutating func placeFunctionRow(x: Double) {
        put(53, "esc", x: x, y: Self.fRow)
        var cursor = x + 1.5
        for (index, item) in fRowKeys.enumerated() {
            if index > 0 && index % 4 == 0 { cursor += 0.35 }
            put(item.0, item.1, x: cursor, y: Self.fRow)
            cursor += 1
        }
    }

    private mutating func placeArrowCluster(x: Double, y: Double) {
        put(123, "←", x: x, y: y)
        put(126, "↑", x: x + 1, y: y, h: 0.5)
        put(125, "↓", x: x + 1, y: y + 0.5, h: 0.5)
        put(124, "→", x: x + 2, y: y)
    }

    // MARK: ANSI

    mutating func ansi(full: Bool) {
        let r1 = Self.r1
        let r2 = r1 + Self.step
        let r3 = r2 + Self.step
        let r4 = r3 + Self.step
        let r5 = r4 + Self.step

        placeFunctionRow(x: 0)
        if full {
            var cursor = 14.9
            for item: (UInt16, String) in [(105, "F13"), (107, "F14"), (113, "F15")] {
                put(item.0, item.1, x: cursor, y: Self.fRow)
                cursor += 1
            }
        }

        var cursor = row([(50, "`")], x: 0, y: r1)
        cursor = row(numberRow, x: cursor, y: r1)
        put(51, "delete", x: cursor, y: r1, w: 1.5)

        cursor = row([(48, "tab", 1.5)], x: 0, y: r2)
        row(qRow, x: cursor, y: r2)

        cursor = row([(57, "caps", 1.75)], x: 0, y: r3)
        cursor = row(aRow, x: cursor, y: r3)
        put(36, "return", x: cursor, y: r3, w: 1.75)

        cursor = row([(56, "shift", 2.25)], x: 0, y: r4)
        cursor = row(zRow, x: cursor, y: r4)
        put(60, "shift", x: cursor, y: r4, w: 2.25)

        cursor = row([(63, "fn", 1), (59, "ctrl", 1), (58, "opt", 1.25), (55, "cmd", 1.25)], x: 0, y: r5)
        cursor = row([(49, "space", 4.75)], x: cursor, y: r5)
        cursor = row([(54, "cmd", 1.25), (61, "opt", 1)], x: cursor, y: r5)
        if !full { placeArrowCluster(x: cursor, y: r5) }   // 全尺寸的方向键在独立分区里，别画两遍

        guard full else { return }

        // 导航区
        cursor = 14.9
        cursor = row([(63, "fn"), (115, "home"), (116, "pgup")], x: cursor, y: r1)
        _ = row([(117, "del"), (119, "end"), (121, "pgdn")], x: 14.9, y: r2)
        put(126, "↑", x: 16.4, y: r3 + 0.5, h: 1)
        cursor = row([(123, "←")], x: 15.4, y: r4 + 0.5)
        cursor = row([(125, "↓")], x: cursor, y: r4 + 0.5)
        _ = row([(124, "→")], x: cursor, y: r4 + 0.5)

        // 数字区
        let padX = 19.2
        _ = row([(71, "clear"), (81, "="), (75, "/"), (67, "*")], x: padX, y: r1)
        _ = row([(89, "7"), (91, "8"), (92, "9"), (78, "-")], x: padX, y: r2)
        _ = row([(86, "4"), (87, "5"), (88, "6"), (69, "+")], x: padX, y: r3)
        _ = row([(83, "1"), (84, "2"), (85, "3")], x: padX, y: r4)
        _ = row([(82, "0", 2.0), (65, ".", 1.0)], x: padX, y: r5)
        put(76, "enter", x: padX + 3, y: r4, h: 2)
    }

    // MARK: ISO

    mutating func iso() {
        let r1 = Self.r1
        let r2 = r1 + Self.step
        let r3 = r2 + Self.step
        let r4 = r3 + Self.step
        let r5 = r4 + Self.step

        placeFunctionRow(x: 0)

        var cursor = row([(10, "§")], x: 0, y: r1)
        cursor = row(numberRow, x: cursor, y: r1)
        put(51, "delete", x: cursor, y: r1, w: 1.5)

        cursor = row([(48, "tab", 1.5)], x: 0, y: r2)
        row(qRow, x: cursor, y: r2)

        cursor = row([(57, "caps", 1.75)], x: 0, y: r3)
        cursor = row(aRow, x: cursor, y: r3)
        put(36, "return", x: cursor, y: r3, w: 1.75)

        cursor = row([(56, "shift", 1.25)], x: 0, y: r4)
        cursor = row([(50, "`")], x: cursor, y: r4)
        cursor = row(zRow, x: cursor, y: r4)
        put(60, "shift", x: cursor, y: r4, w: 2.25)

        cursor = row([(63, "fn", 1), (59, "ctrl", 1), (58, "opt", 1.25), (55, "cmd", 1.25)], x: 0, y: r5)
        cursor = row([(49, "space", 4.75)], x: cursor, y: r5)
        cursor = row([(54, "cmd", 1.25), (61, "opt", 1)], x: cursor, y: r5)
        placeArrowCluster(x: cursor, y: r5)
    }

    // MARK: JIS

    mutating func jis() {
        let r1 = Self.r1
        let r2 = r1 + Self.step
        let r3 = r2 + Self.step
        let r4 = r3 + Self.step
        let r5 = r4 + Self.step

        placeFunctionRow(x: 0)

        var cursor = row([(50, "`")], x: 0, y: r1)
        cursor = row(numberRow, x: cursor, y: r1)
        cursor = row([(93, "¥")], x: cursor, y: r1)
        put(51, "delete", x: cursor, y: r1, w: 1.5)

        cursor = row([(48, "tab", 1.5)], x: 0, y: r2)
        row(qRow, x: cursor, y: r2)

        cursor = row([(57, "caps", 1.75)], x: 0, y: r3)
        cursor = row(aRow, x: cursor, y: r3)
        put(36, "return", x: cursor, y: r3, w: 1.75)

        cursor = row([(56, "shift", 2.25)], x: 0, y: r4)
        cursor = row(zRow, x: cursor, y: r4)
        put(60, "shift", x: cursor, y: r4, w: 2.25)

        cursor = row([(63, "fn", 1), (59, "ctrl", 1), (58, "opt", 1.25), (55, "cmd", 1.25)], x: 0, y: r5)
        cursor = row([(102, "英数", 1.25)], x: cursor, y: r5)
        cursor = row([(49, "space", 3.0)], x: cursor, y: r5)
        cursor = row([(104, "かな", 1.25)], x: cursor, y: r5)
        cursor = row([(54, "cmd", 1.25), (61, "opt", 1)], x: cursor, y: r5)
        placeArrowCluster(x: cursor, y: r5)
    }
}

// MARK: - 缓存

public enum KeyboardLayouts {
    private static var cache: [KeyboardLayoutID: KeyboardLayout] = [:]

    public static func layout(_ id: KeyboardLayoutID) -> KeyboardLayout {
        if let cached = cache[id] { return cached }
        let built = KeyboardLayout.build(id)
        cache[id] = built
        return built
    }
}
