import Foundation

// MARK: - 外设信号模型
//
// 这一层只回答一个问题：这块键盘 / 这只鼠标 / 这块触控板，
// 有没有在「输入本身」上表现出不该有的行为 —— 双击、跳点、断流。
// 判定完全发生在事件流里，落盘的只有计数，不存按键内容、不存光标位置。

public enum PeripheralKind: String, Codable, CaseIterable, Sendable {
    case keyboard
    case mouse
    case trackpad

    public var title: String {
        switch self {
        case .keyboard: return "键盘"
        case .mouse: return "鼠标"
        case .trackpad: return "触控板"
        }
    }
}

/// 一台设备在一天里的信号
public struct DeviceSignals: Codable, Equatable {
    public var kind: PeripheralKind
    public var name: String
    /// 基础事件数：键盘 = 按键次数，鼠标 = 指针报文数，触控板 = 报点帧数
    public var samples: Int
    /// 异常计数。键见 `Metric`
    public var metrics: [String: Int]

    public init(kind: PeripheralKind, name: String) {
        self.kind = kind
        self.name = name
        samples = 0
        metrics = [:]
    }

    public func value(_ metric: String) -> Int { metrics[metric] ?? 0 }
}

public struct HardwareDay: Codable, Equatable {
    /// key = "kind|设备名"
    public var devices: [String: DeviceSignals]

    public init() { devices = [:] }

    public static func key(kind: PeripheralKind, name: String) -> String {
        "\(kind.rawValue)|\(name)"
    }

    public var isEmpty: Bool { devices.isEmpty }
}

public enum Metric {
    /// 打字后 300ms 内立刻回删（可能是重复字符，也可能只是打错了）
    public static let keyFix = "fix"
    /// 连续回删 ≥2 次后重新输入
    public static let keyRewrite = "rewrite"
    /// 同一颗键 70ms 内被按下两次 —— 人手做不到，通常是开关抖动
    public static let keyChatter = "chatter"
    /// 非修饰键按住超过 8 秒（卡键）
    public static let keyHold = "hold"

    /// 单次位移远超近期中位数 —— 光标「跳」了一下
    public static let mouseJump = "jump"
    /// 连续移动中突然断流 120–600ms，然后又接着动
    public static let mouseStall = "stall"
    /// 同一键 45ms 内连按两次（机械抖动 / 双击误判）
    public static let mouseBounce = "bounce"

    public static let padJump = "jump"
    public static let padStall = "stall"
}

// MARK: - 流式判定器

/// 每个外设一套判定，边收边算，只留 O(1) 的状态。
/// 线程安全由调用方（Engine 的 lock）保证。
public final class HardwareProbe {
    public private(set) var day = HardwareDay()

    // 键盘
    private var lastKey: (code: UInt16, t: Double)?
    private var backspaceRun = 0
    private var backspaceAt = 0.0
    private var keyDownAt: [UInt16: Double] = [:]

    // 指针（鼠标）
    private struct PointerState {
        var lastAt: Double
        var run: Int              // 连续报文数（间隔 < 60ms）
        var recent: [Double]      // 最近 24 次位移，算中位数
        var prev: Double          // 上一次位移
        var prevPrev: Double      // 再上一次位移
        var prevMedian: Double?   // 上一次位移发生时，历史位移的中位数
    }
    private var pointers: [String: PointerState] = [:]
    private var lastClick: [String: (t: Double, index: Int)] = [:]

    // 触控板 / MT 帧
    private struct FrameState {
        var t: Double
        var point: (Double, Double)?
        var recent: [Double]
        var prev: Double
        var prevPrev: Double
        var prevMedian: Double?
        var prevFast: Bool        // 上一帧间隔正常（不是断流后的第一帧）
    }
    private var frames: [String: FrameState] = [:]

    public init() {}

    public func reset(to newDay: HardwareDay = HardwareDay()) {
        day = newDay
        lastKey = nil
        backspaceRun = 0
        backspaceAt = 0
        keyDownAt.removeAll()
        pointers.removeAll()
        lastClick.removeAll()
        frames.removeAll()
    }

    // MARK: 写入

    private func bump(_ kind: PeripheralKind, _ name: String,
                      sample: Bool = false, metric: String? = nil, by: Int = 1) {
        let key = HardwareDay.key(kind: kind, name: name)
        var bucket = day.devices[key] ?? DeviceSignals(kind: kind, name: name)
        if sample { bucket.samples += 1 }
        if let metric { bucket.metrics[metric, default: 0] += by }
        day.devices[key] = bucket
    }

    private static let modifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let deletes: Set<UInt16> = [51, 117]   // delete / forward delete

    /// 键盘按下。`code` 是虚拟键码（kVK_*）。
    public func keyDown(_ code: UInt16, device name: String) {
        let t = ProcessInfo.processInfo.systemUptime
        bump(.keyboard, name, sample: true)
        keyDownAt[code] = t

        // 修饰键不参与打字节奏判定（⌘ 组合、按住 shift 都很正常）
        guard !Self.modifiers.contains(code) else { return }

        if Self.deletes.contains(code) {
            // 「打了字 → 立刻回删」= 可能是重复字符被手动删掉
            if let last = lastKey, !Self.deletes.contains(last.code), t - last.t < 0.30 {
                bump(.keyboard, name, metric: Metric.keyFix)
            }
            if t - backspaceAt < 1.0 { backspaceRun += 1 } else { backspaceRun = 1 }
            backspaceAt = t
            lastKey = (code, t)
            return
        }

        // 「连续回删 → 重新输入」
        if backspaceRun >= 2, t - backspaceAt < 2.0 {
            bump(.keyboard, name, metric: Metric.keyRewrite)
            backspaceRun = 0
        }
        // 同一颗键 70ms 内两次：人手极限之外，基本就是开关在抖
        if let last = lastKey, last.code == code, t - last.t < 0.070 {
            bump(.keyboard, name, metric: Metric.keyChatter)
        }
        lastKey = (code, t)
    }

    public func keyUp(_ code: UInt16, device name: String) {
        let t = ProcessInfo.processInfo.systemUptime
        defer { keyDownAt.removeValue(forKey: code) }
        guard !Self.modifiers.contains(code), let start = keyDownAt[code] else { return }
        // 卡键：一直按着不松。超过 8 秒除了游戏，几乎都是硬件/系统层面卡住了
        if t - start > 8 { bump(.keyboard, name, metric: Metric.keyHold) }
    }

    /// 鼠标指针报文（相对位移，单位是设备点数，不是像素）
    public func pointer(dx: Double, dy: Double, device name: String) {
        let t = ProcessInfo.processInfo.systemUptime
        bump(.mouse, name, sample: true)
        let distance = (dx * dx + dy * dy).squareRoot()

        var state = pointers[name] ?? PointerState(lastAt: t, run: 0, recent: [],
                                                   prev: 0, prevPrev: 0, prevMedian: nil)
        let gap = t - state.lastAt

        // 跳点：必须是「孤立尖峰」—— 前后两次位移都小，只有它是大的。
        // 甩鼠标时是一串连续的大的（prevPrev 也大），收尾那次（下一次变小）也不会误判。
        if let median = state.prevMedian,
           state.prev > max(60, median * 8),
           state.prevPrev < state.prev * 0.4,
           distance < state.prev * 0.4 {
            bump(.mouse, name, metric: Metric.mouseJump)
        }

        // 断流：本来在连续移动（run ≥ 5），突然 120–600ms 没有报文，接着又动
        if state.run >= 5, gap > 0.12, gap < 0.60, distance > 2 {
            bump(.mouse, name, metric: Metric.mouseStall)
        }

        // 记录「这次」的位移与它当时的参照系，等下一次报到来判断是不是尖峰。
        // 用中位数而不是平均值：快速移动时整体都大，不会把正常的快划当成跳点。
        state.prevMedian = state.recent.count >= 8 ? Self.median(state.recent) : nil
        state.prevPrev = state.prev
        state.prev = distance
        state.recent.append(distance)
        if state.recent.count > 24 { state.recent.removeFirst(state.recent.count - 24) }
        state.run = gap < 0.06 ? state.run + 1 : 0
        state.lastAt = t
        pointers[name] = state
    }

    public func click(device name: String, index: Int) {
        let t = ProcessInfo.processInfo.systemUptime
        if let last = lastClick[name], last.index == index, t - last.t < 0.045 {
            bump(.mouse, name, metric: Metric.mouseBounce)
        }
        lastClick[name] = (t, index)
    }

    /// 触控板报点帧。`primary` 是主接触点的归一化坐标（0–1，未翻 Y）。
    public func frame(device name: String, primary: (Double, Double)?) {
        let t = ProcessInfo.processInfo.systemUptime
        bump(.trackpad, name, sample: true)

        guard var state = frames[name] else {
            frames[name] = FrameState(t: t, point: primary, recent: [],
                                      prev: 0, prevPrev: 0, prevMedian: nil, prevFast: false)
            return
        }
        let dt = t - state.t
        if let last = state.point, let cur = primary {
            let distance = ((cur.0 - last.0) * (cur.0 - last.0)
                            + (cur.1 - last.1) * (cur.1 - last.1)).squareRoot()

            // 单帧跳变：前后两帧都小、只有中间那帧跨过一大块板面。
            // 手指快速滑动是一串连续的大位移，不会命中。
            if state.prevFast, let median = state.prevMedian,
               state.prev > max(0.15, median * 5),
               state.prevPrev < state.prev * 0.4,
               distance < state.prev * 0.4 {
                bump(.trackpad, name, metric: Metric.padJump)
            }

            // 报点中断：手指还在板上，但中间断了 120ms 以上
            if dt > 0.12, dt < 0.60 {
                bump(.trackpad, name, metric: Metric.padStall)
            }

            state.prevMedian = state.recent.count >= 6 ? Self.median(state.recent) : nil
            state.prevPrev = state.prev
            state.prev = distance
            state.prevFast = dt < 0.05
            state.recent.append(distance)
            if state.recent.count > 16 { state.recent.removeFirst(state.recent.count - 16) }
        } else {
            // 手指抬起：清掉基线，避免下次落指的第一帧被当成跳变
            state.prev = 0
            state.prevPrev = 0
            state.prevMedian = nil
            state.prevFast = false
            state.recent.removeAll()
        }
        state.t = t
        state.point = primary
        frames[name] = state
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - 跨天聚合与判定

public struct HardwareAggregate {
    public var kind: PeripheralKind
    public var device: String
    public var samples: Int = 0
    public var metrics: [String: Int] = [:]
    /// 每个指标分别出现在几天里 —— 只出现在一天的不算「经常」
    public var metricDays: [String: Int] = [:]
    public var dayCount: Int = 0

    public func value(_ metric: String) -> Int { metrics[metric] ?? 0 }
    public func rate(_ metric: String, per: Double = 1000) -> Double {
        guard samples > 0 else { return 0 }
        return Double(value(metric)) / Double(samples) * per
    }
}

public struct HardwareFinding: Identifiable {
    public enum Level: String {
        case notice
        case warning
    }

    public struct Row: Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var kind: PeripheralKind
    public var device: String
    public var level: Level
    public var headline: String
    public var detail: String
    public var rows: [Row]
    public var advice: String

    public init(kind: PeripheralKind, device: String, level: Level,
                headline: String, detail: String, rows: [Row], advice: String) {
        self.kind = kind
        self.device = device
        self.level = level
        self.headline = headline
        self.detail = detail
        self.rows = rows
        self.advice = advice
    }

    public var id: String { "\(kind.rawValue)|\(device)" }
}

public enum HardwareWatch {
    /// 判定门槛。数值都写在「每千次样本」上，因为不同人用机强度差很多。
    public enum Limit {
        // 键盘
        public static let chatterCount = 6
        public static let chatterDays = 2
        public static let keyFixRate = 40.0        // 每千次按键 40 次立刻回删 = 4%
        // 鼠标
        public static let mouseJumpCount = 12
        public static let mouseJumpRate = 0.9      // 每千次报文
        public static let mouseStallCount = 25
        public static let mouseBounceCount = 10
        // 触控板
        public static let padJumpCount = 20
        public static let padStallCount = 40

        public static let minKeySamples = 500
        public static let minMouseSamples = 3000
        public static let minPadSamples = 3000
    }

    public static func aggregate(_ days: [DayStats]) -> [HardwareAggregate] {
        var result: [String: HardwareAggregate] = [:]
        for day in days {
            for (key, bucket) in day.hardware.devices {
                var agg = result[key] ?? HardwareAggregate(kind: bucket.kind, device: bucket.name)
                agg.samples += bucket.samples
                agg.dayCount += 1
                for (metric, count) in bucket.metrics where count > 0 {
                    agg.metrics[metric, default: 0] += count
                    agg.metricDays[metric, default: 0] += 1
                }
                result[key] = agg
            }
        }
        return result.values.sorted {
            $0.kind == $1.kind ? $0.device < $1.device : $0.kind.rawValue < $1.kind.rawValue
        }
    }

    public static func findings(_ days: [DayStats]) -> [HardwareFinding] {
        aggregate(days).compactMap { evaluate($0) }.sorted { $0.level.rawValue > $1.level.rawValue }
    }

    public static func finding(for kind: PeripheralKind, in days: [DayStats]) -> HardwareFinding? {
        findings(days).first { $0.kind == kind }
    }

    // MARK: 每类外设一套判定

    private static func evaluate(_ agg: HardwareAggregate) -> HardwareFinding? {
        switch agg.kind {
        case .keyboard: return keyboard(agg)
        case .mouse: return mouse(agg)
        case .trackpad: return trackpad(agg)
        }
    }

    private static func keyboard(_ agg: HardwareAggregate) -> HardwareFinding? {
        guard agg.samples >= Limit.minKeySamples else { return nil }
        let chatter = agg.value(Metric.keyChatter)
        let chatterDays = agg.metricDays[Metric.keyChatter] ?? 0
        let fix = agg.value(Metric.keyFix)
        let rewrite = agg.value(Metric.keyRewrite)
        let hold = agg.value(Metric.keyHold)
        let fixRate = agg.rate(Metric.keyFix)

        // 重复触发是主证据；「立刻回删」只做人打错字的参照，单独不足以判定
        let chatterHit = chatter >= Limit.chatterCount
            && (chatterDays >= Limit.chatterDays || chatter >= Limit.chatterCount * 2)
        let fixHit = fixRate >= Limit.keyFixRate && rewrite >= 15
        guard chatterHit || fixHit || hold >= 3 else { return nil }

        var rows: [HardwareFinding.Row] = [
            .init(label: "重复触发", value: "\(chatter) 次 · \(chatterDays) 天"),
            .init(label: "打字后立刻回删", value: String(format: "%d 次（%.1f%%）", fix, fixRate / 10)),
            .init(label: "连删后重打", value: "\(rewrite) 次")
        ]
        if hold > 0 { rows.append(.init(label: "长按不松", value: "\(hold) 次")) }
        rows.append(.init(label: "样本", value: "\(agg.samples) 次按键 · \(agg.dayCount) 天"))

        let level: HardwareFinding.Level = chatter >= Limit.chatterCount * 3 ? .warning : .notice
        let headline = chatterHit
            ? "键盘可能在重复触发：\(agg.device)"
            : "键盘的回删比例偏高：\(agg.device)"
        let detail = chatterHit
            ? "同一颗键在 70 毫秒内被按下两次 —— 这比人手快到极限还快，通常是轴体/薄膜开关在抖动，多出来的那个字符只能手动删掉。"
            : "打字后 300 毫秒内立刻回删的比例到了 \(String(format: "%.1f", fixRate / 10))%。这也能是打字习惯，所以只作为参考，不单独下结论。"

        return HardwareFinding(kind: .keyboard, device: agg.device, level: level,
                               headline: headline, detail: detail, rows: rows,
                               advice: "换一根线或换一台机器对比一天；蓝牙键盘把接收器/扩展坞挪远一点再看。")
    }

    private static func mouse(_ agg: HardwareAggregate) -> HardwareFinding? {
        guard agg.samples >= Limit.minMouseSamples else { return nil }
        let jump = agg.value(Metric.mouseJump)
        let stall = agg.value(Metric.mouseStall)
        let bounce = agg.value(Metric.mouseBounce)
        let jumpRate = agg.rate(Metric.mouseJump)

        let jumpHit = jump >= Limit.mouseJumpCount && jumpRate >= Limit.mouseJumpRate
        guard jumpHit || stall >= Limit.mouseStallCount || bounce >= Limit.mouseBounceCount else { return nil }

        let rows: [HardwareFinding.Row] = [
            .init(label: "光标跳点", value: String(format: "%d 次 · 每千次 %.2f", jump, jumpRate)),
            .init(label: "移动中断", value: "\(stall) 次"),
            .init(label: "连击抖动", value: "\(bounce) 次"),
            .init(label: "样本", value: "\(agg.samples) 次报文 · \(agg.dayCount) 天")
        ]

        let level: HardwareFinding.Level = (jumpHit && stall >= Limit.mouseStallCount) ? .warning : .notice
        let detail = "统计到单次位移远超近期水平的跳点，以及连续移动中 120–600 毫秒的断流。传感器进灰、无线链路被干扰、USB 供电不稳都会是这个样子 —— 光标顿一下，然后跳过去。"
        return HardwareFinding(kind: .mouse, device: agg.device, level: level,
                               headline: "鼠标指针出现了跳变：\(agg.device)",
                               detail: detail, rows: rows,
                               advice: "先换一个 USB 口、去掉扩展坞试一天；2.4G 接收器别和 USB 3 设备挤在一起。只统计位移，不记录光标位置。")
    }

    private static func trackpad(_ agg: HardwareAggregate) -> HardwareFinding? {
        guard agg.samples >= Limit.minPadSamples else { return nil }
        let jump = agg.value(Metric.padJump)
        let stall = agg.value(Metric.padStall)
        guard jump >= Limit.padJumpCount || stall >= Limit.padStallCount else { return nil }

        let rows: [HardwareFinding.Row] = [
            .init(label: "单帧跳变", value: "\(jump) 次"),
            .init(label: "报点中断", value: "\(stall) 次"),
            .init(label: "样本", value: "\(agg.samples) 帧 · \(agg.dayCount) 天")
        ]
        let level: HardwareFinding.Level = (jump >= Limit.padJumpCount && stall >= Limit.padStallCount)
            ? .warning : .notice
        return HardwareFinding(kind: .trackpad, device: agg.device, level: level,
                               headline: "触控板报点不太稳：\(agg.device)",
                               detail: "出现了单帧跨越板面一大块的跳变，或者手指还在板上、报点却断了 120 毫秒以上。可能是排线、静电，也可能只是手掌压到了边缘。",
                               rows: rows,
                               advice: "擦一遍表面、拔掉电源再试；如果只在某个位置复现，记下时间点去售后。")
    }
}
