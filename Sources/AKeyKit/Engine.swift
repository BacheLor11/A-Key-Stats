import Foundation
import AppKit

/// 实时输入事件：给「检测」页用，暂停记录时也照常推送（测试不该被记录开关挡住）
public struct LiveInputEvent {
    public enum Kind {
        case keyDown
        case keyUp
        case mouseDown
        case mouseUp
        /// 同一颗键被系统重复上报（已从统计里去掉，但检测页要看见）
        case duplicateKey
    }

    public var kind: Kind
    public var code: UInt16      // 键码；鼠标事件里是按钮序号 0/1/2
    public var device: String
    public var at: Date

    public init(kind: Kind, code: UInt16, device: String, at: Date = Date()) {
        self.kind = kind; self.code = code; self.device = device; self.at = at
    }
}

/// 采集引擎：把键、鼠标、触控板三路事件汇总进「今天」这一份 DayStats，
/// 顺带把触控板原始轨迹降采样落盘（可回放）。
public final class Engine {
    public static let shared = Engine()

    // MARK: 对外状态

    public private(set) var inputAccess: InputTap.Access = InputTap.access()
    public private(set) var padDevices: [MTDeviceInfo] = []
    public private(set) var isRunning = false
    public private(set) var isPaused = false
    public private(set) var trajectoryVersion = 0

    public var onUpdate: (() -> Void)?
    public var onLiveEvent: ((LiveInputEvent) -> Void)?

    /// 触控板归一化坐标原点在左下，UI 画布原点在左上。
    public var flipPadY = true
    public var flipMouseY = true

    private let store = Store.shared
    private let input = InputTap()
    private let pad = PadTap()
    private let lock = NSLock()

    private var today: DayStats
    private var padWriter: TrajectoryWriter?
    private var mouseWriter: TrajectoryWriter?
    private var fingerLast: [Int32: (x: Double, y: Double)] = [:]
    private var lastEventAt: Date?
    private var lastPadContactAt: Date?
    private var lastMouseContactAt: Date?
    private var timers: [Timer] = []
    private var scrollMonitor: Any?
    private var localScrollMonitor: Any?
    /// 当前滚动手势是不是触控板发起的（nil = 还没判定）
    private var scrollSessionPad: Bool?

    // MARK: 初始化

    private init() {
        // 早期版本存的是 HID usage，先一次性换算成虚拟键码，再读当天数据
        store.migrateKeycodesIfNeeded()
        let key = DayKey.of(Date())
        today = store.load(day: key) ?? DayStats(date: key)
        openWriters(for: key)
    }

    private func openWriters(for key: String) {
        padWriter?.close()
        mouseWriter?.close()
        padWriter = TrajectoryWriter(url: store.trajectoryURL(day: key, kind: .pad))
        mouseWriter = TrajectoryWriter(url: store.trajectoryURL(day: key, kind: .mouse))
    }

    // MARK: 生命周期

    public func start() {
        guard !isRunning else { return }
        inputAccess = InputTap.access()
        if inputAccess != .granted { InputTap.requestAccess() }

        input.onKeyDown = { [weak self] code, device in
            self?.onLiveEvent?(LiveInputEvent(kind: .keyDown, code: code, device: device))
            self?.recordKey(code)
        }
        input.onKeyUp = { [weak self] code, device in
            self?.onLiveEvent?(LiveInputEvent(kind: .keyUp, code: code, device: device))
        }
        input.onDuplicateKey = { [weak self] code, device in
            self?.onLiveEvent?(LiveInputEvent(kind: .duplicateKey, code: code, device: device))
        }
        input.onMouseButton = { [weak self] index, device in
            self?.onLiveEvent?(LiveInputEvent(kind: .mouseDown, code: UInt16(max(0, index)), device: device))
            self?.recordMouseButton(index)
        }
        input.onMouseButtonUp = { [weak self] index, device in
            self?.onLiveEvent?(LiveInputEvent(kind: .mouseUp, code: UInt16(max(0, index)), device: device))
        }
        _ = input.start()

        pad.onFrame = { [weak self] info, contacts in
            self?.recordContacts(info: info, contacts: contacts)
        }
        _ = pad.start()
        padDevices = pad.devices

        installScrollMonitor()

        // 1 秒刷一次界面，20 秒落一次盘
        let refresh = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        let save = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.flush()
        }
        timers = [refresh, save]
        isRunning = true
        onUpdate?()
    }

    public func stop() {
        input.stop()
        pad.stop()
        for timer in timers { timer.invalidate() }
        timers.removeAll()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        scrollMonitor = nil
        localScrollMonitor = nil
        flush()
        isRunning = false
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused { flush() }
        onUpdate?()
    }

    // MARK: 记录

    private func markActive() {
        let now = Date()
        if let last = lastEventAt {
            let gap = now.timeIntervalSince(last)
            if gap > 0, gap < 60 { today.activeSeconds += Int(gap.rounded()) }
        }
        lastEventAt = now
    }

    private func recordKey(_ code: UInt16) {
        guard !isPaused else { return }
        lock.lock()
        rolloverIfNeeded()
        today.keys[String(code), default: 0] += 1
        let hour = DayKey.hour(of: Date())
        if hour >= 0, hour < 24 { today.hourly[hour] += 1 }
        markActive()
        lock.unlock()
    }

    private func recordMouseButton(_ index: Int) {
        guard !isPaused else { return }
        lock.lock()
        rolloverIfNeeded()
        switch index {
        case 0: today.clicks.left += 1
        case 1: today.clicks.right += 1
        case 2: today.clicks.middle += 1
        default: break
        }
        markActive()
        lock.unlock()
    }

    private func recordScroll(from event: NSEvent) {
        // 触控板/妙控鼠标的滚动带 phase（连续手势），传统滚轮是离散刻度。
        // 一个手势会话内的所有事件（含松手后的惯性滚动）都归给同一个来源。
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) || (!isGesture && scrollSessionPad == nil) {
            scrollSessionPad = isGesture ? recentContactIsPad() : false
        }
        let fromPad = isGesture ? (scrollSessionPad ?? false) : false
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { scrollSessionPad = nil }

        guard !isPaused else { return }
        lock.lock()
        rolloverIfNeeded()
        if fromPad {
            today.clicks.padScroll += 1
        } else {
            today.clicks.scroll += 1
        }
        markActive()
        lock.unlock()
    }

    /// 最近 0.3 秒内有接触点的设备，判定这次手势是谁发的
    private func recentContactIsPad() -> Bool {
        let now = Date()
        let pad = lastPadContactAt.map { now.timeIntervalSince($0) < 0.3 } ?? false
        let mouse = lastMouseContactAt.map { now.timeIntervalSince($0) < 0.3 } ?? false
        if mouse && !pad { return false }
        if pad && !mouse { return true }
        if let p = lastPadContactAt, let m = lastMouseContactAt { return p > m }
        return false
    }

    private func recordContacts(info: MTDeviceInfo, contacts: [TouchContact]) {
        guard !isPaused else { return }
        let isMouse = info.kind == .mouse
        let flip = isMouse ? flipMouseY : flipPadY
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let seconds = Float(now.timeIntervalSince(dayStart))

        lock.lock()
        rolloverIfNeeded()
        if isMouse { lastMouseContactAt = now } else { lastPadContactAt = now }
        for contact in contacts {
            let x = contact.x
            let y = flip ? 1 - contact.y : contact.y
            // 归一化后的 finger id 塞进轨迹，渲染时按 id 分段画
            let finger = UInt16(truncatingIfNeeded: contact.id)
            if isMouse {
                today.mouseGrid.add(x: x, y: y)
                today.mouseContacts += 1
                mouseWriter?.append(t: seconds, x: Float(x), y: Float(y), id: finger)
                if let last = fingerLast[contact.id &+ 1000] {
                    today.mouseTravel += ((x - last.x) * (x - last.x) + (y - last.y) * (y - last.y)).squareRoot()
                }
                fingerLast[contact.id &+ 1000] = (x, y)
            } else {
                today.padGrid.add(x: x, y: y)
                today.padContacts += 1
                today.padMaxContact = max(today.padMaxContact, contact.size)
                padWriter?.append(t: seconds, x: Float(x), y: Float(y), id: finger)
                if let last = fingerLast[contact.id] {
                    today.padTravel += ((x - last.x) * (x - last.x) + (y - last.y) * (y - last.y)).squareRoot()
                }
                fingerLast[contact.id] = (x, y)
            }
        }
        markActive()
        lock.unlock()
    }

    private func installScrollMonitor() {
        let mask: NSEvent.EventTypeMask = [.scrollWheel]
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.recordScroll(from: event)
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.recordScroll(from: event)
            return event
        }
    }

    // MARK: 跨天与落盘

    private func rolloverIfNeeded() {
        let key = DayKey.of(Date())
        guard key != today.date else { return }
        let finished = today
        store.save(finished)
        padWriter?.close()
        mouseWriter?.close()
        today = store.load(day: key) ?? DayStats(date: key)
        openWriters(for: key)
        fingerLast.removeAll()
        trajectoryVersion &+= 1
    }

    public func flush() {
        lock.lock()
        rolloverIfNeeded()
        let snapshot = today
        padWriter?.flush()
        mouseWriter?.flush()
        lock.unlock()
        store.save(snapshot)
        trajectoryVersion &+= 1
    }

    private func tick() {
        // 权限可能在用户去系统设置里改过
        inputAccess = InputTap.access()
        onUpdate?()
    }

    // MARK: 读

    public func snapshot() -> DayStats {
        lock.lock()
        defer { lock.unlock() }
        return today
    }

    public func recent(_ days: Int) -> [DayStats] {
        let current = snapshot()
        var list = store.recent(days, endingAt: Date())
        if let last = list.indices.last { list[last] = current }
        return list
    }

    public func trajectory(kind: TrajKind, day: String? = nil) -> [TrajPoint] {
        let key = day ?? snapshot().date
        return store.trajectory(day: key, kind: kind)
    }

    public func trajectoryBytes() -> Int {
        store.trajectorySize(day: snapshot().date)
    }

    public func resetAll() {
        lock.lock()
        store.resetAll()
        let key = DayKey.of(Date())
        today = DayStats(date: key)
        fingerLast.removeAll()
        openWriters(for: key)
        lock.unlock()
        trajectoryVersion &+= 1
        onUpdate?()
    }

    public func requestInputAccess() {
        InputTap.requestAccess()
        input.refreshDevices()
        inputAccess = InputTap.access()
        onUpdate?()
    }

    public var storedDeviceNames: (keyboards: [String], mice: [String]) {
        (input.keyboardNames, input.mouseNames)
    }

    /// 被去重挡掉的重复上报次数（正常应该是 0；不为 0 说明键盘/系统在重复发同一次按下）
    public var dedupedKeyEvents: Int { input.dedupedEvents }
    /// 映射表里找不到的 usage 明细
    public var unmappedKeyUsages: [UInt16: Int] { input.unmappedUsages }

    public var dataDirectory: URL { store.root }
}
