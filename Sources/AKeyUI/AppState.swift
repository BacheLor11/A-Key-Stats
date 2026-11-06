import SwiftUI
import AppKit
import AKeyKit

/// 偏好设置统一走这一个域。
///
/// 独立 app 的 bundle id 就是 `com.aibao.AKeyStats`，所以以前用
/// `UserDefaults.standard` 恰好也落在这个域里；但作为 A-Kit 插件运行时
/// `Bundle.main` 是 A-Kit，`.standard` 会跑到 A-Kit 的域去 ——
/// 用户在独立 app 里设的键盘布局、Y 轴翻转，在 A-Kit 里就全部读不到。
///
/// 显式指定 suiteName 之后，两种形态读写的是同一份偏好。
public enum AKSPrefs {
    public static let suiteName = "com.aibao.AKeyStats"
    public static let shared: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
}

@MainActor
public final class AppState: ObservableObject {
    public enum Page: String, CaseIterable, Identifiable {
        case dashboard, keyboard, trackpad, mouse, tester, history, settings

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .dashboard: return "概览"
            case .keyboard: return "键盘"
            case .trackpad: return "触控板"
            case .mouse: return "鼠标"
            case .tester: return "检测"
            case .history: return "历史"
            case .settings: return "设置"
            }
        }

        public var symbol: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .keyboard: return "keyboard"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .mouse: return "computermouse"
            case .tester: return "waveform.path.ecg"
            case .history: return "calendar"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    /// 概览页中间那排小图：键盘是常驻的，触控板与鼠标可以按需显示
    public enum OverviewPanels: String, CaseIterable, Identifiable {
        case both
        case trackpadOnly
        case mouseOnly

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .both: return "触控板 + 鼠标"
            case .trackpadOnly: return "只显示触控板"
            case .mouseOnly: return "只显示鼠标"
            }
        }

        public var showsTrackpad: Bool { self != .mouseOnly }
        public var showsMouse: Bool { self != .trackpadOnly }
    }

    let engine = Engine.shared
    /// 检测页的实时状态（不落盘、不影响统计）
    public let tester = TesterStore()

    @Published public var page: Page = .dashboard
    @Published public private(set) var today: DayStats
    @Published public private(set) var recentDays: [DayStats] = []
    @Published public private(set) var padDevices: [MTDeviceInfo] = []
    @Published public private(set) var inputAccess: InputTap.Access = .unknown
    @Published public private(set) var isPaused = false
    @Published public private(set) var storedDeviceNames: (keyboards: [String], mice: [String]) = ([], [])
    @Published public private(set) var trajectoryBytes = 0
    /// 被去重挡掉的重复上报（键盘一次按下发了两遍的情况）
    @Published public private(set) var dedupedKeyEvents = 0
    @Published public private(set) var unmappedKeyCount = 0

    /// 概览页当前看的周期
    @Published public var statsPeriod: StatsPeriod = .today {
        didSet {
            guard persistPreferences else { return }
            AKSPrefs.shared.set(statsPeriod.rawValue, forKey: "statsPeriod")
        }
    }
    /// 四个周期各自的聚合结果（历史缓存 + 今天实时，见 rebuildPeriods）
    @Published public private(set) var periods: [StatsPeriod: PeriodStats] = [:]

    /// 除今天以外的历史聚合，只在跨天时重建一次 —— 否则每秒都要读一遍所有日文件
    private var historyPeriods: [StatsPeriod: PeriodStats] = [:]
    private var historyBuiltFor = ""

    /// 离屏渲染时不写偏好，免得截图把用户设置改掉
    public var persistPreferences = true

    @Published public var layoutID: KeyboardLayoutID {
        didSet {
            guard persistPreferences else { return }
            AKSPrefs.shared.set(layoutID.rawValue, forKey: "layoutID")
        }
    }
    @Published public var flipPadY: Bool {
        didSet {
            engine.flipPadY = flipPadY
            guard persistPreferences else { return }
            AKSPrefs.shared.set(flipPadY, forKey: "flipPadY")
        }
    }
    @Published public var flipMouseY: Bool {
        didSet {
            engine.flipMouseY = flipMouseY
            guard persistPreferences else { return }
            AKSPrefs.shared.set(flipMouseY, forKey: "flipMouseY")
        }
    }
    @Published public var overviewPanels: OverviewPanels {
        didSet {
            guard persistPreferences else { return }
            AKSPrefs.shared.set(overviewPanels.rawValue, forKey: "overviewPanels")
        }
    }

    @Published public private(set) var padTrajectory: [TrajPoint] = []
    @Published public private(set) var mouseTrajectory: [TrajPoint] = []
    @Published public var showTrail = true
    @Published public var replayProgress: Double = 1
    @Published public private(set) var isReplaying = false

    public var onMenuBarTitleChange: ((String) -> Void)?

    private var refreshTimer: Timer?
    private var replayTimer: Timer?
    private var lastTrajectoryVersion = -1

    public init() {
        let defaults = AKSPrefs.shared
        layoutID = KeyboardLayoutID(rawValue: defaults.string(forKey: "layoutID") ?? "") ?? .ansiCompact
        let pad = defaults.object(forKey: "flipPadY") as? Bool
        let mouse = defaults.object(forKey: "flipMouseY") as? Bool
        flipPadY = pad ?? true
        flipMouseY = mouse ?? true
        overviewPanels = OverviewPanels(rawValue: defaults.string(forKey: "overviewPanels") ?? "") ?? .both
        statsPeriod = StatsPeriod(rawValue: defaults.string(forKey: "statsPeriod") ?? "") ?? .today
        today = Engine.shared.snapshot()
        engine.flipPadY = pad ?? true
        engine.flipMouseY = mouse ?? true

        engine.onUpdate = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        engine.onLiveEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.tester.handle(event, layout: self.layout)
            }
        }
        refresh()
        engine.start()
        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 停掉采集与定时器，并把当天数据刷盘。
    ///
    /// 插件形态在 `deactivate()` 里调 —— 宿主进程还活着，采集不能一直跑着。
    /// 独立 app 退出前也走这里，行为跟原来 `Engine.shared.flush()` 一致。
    public func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        replayTimer?.invalidate()
        replayTimer = nil
        engine.onUpdate = nil
        engine.onLiveEvent = nil
        engine.stop()
        engine.flush()
    }

    // MARK: 刷新

    /// 离屏渲染时冻结刷新，免得演示数据被真实快照覆盖
    public var frozen = false

    public func refresh() {
        guard !frozen else { return }
        let snapshot = engine.snapshot()
        today = snapshot
        recentDays = engine.recent(14)
        padDevices = engine.padDevices
        inputAccess = engine.inputAccess
        isPaused = engine.isPaused
        storedDeviceNames = engine.storedDeviceNames
        trajectoryBytes = engine.trajectoryBytes()
        dedupedKeyEvents = engine.dedupedKeyEvents
        unmappedKeyCount = engine.unmappedKeyUsages.values.reduce(0, +)
        rebuildPeriods(todayStats: snapshot)

        if engine.trajectoryVersion != lastTrajectoryVersion {
            lastTrajectoryVersion = engine.trajectoryVersion
            padTrajectory = engine.trajectory(kind: .pad)
            mouseTrajectory = engine.trajectory(kind: .mouse)
        }

        let title = "\(Self.shortNumber(today.keyTotal)) 键"
        onMenuBarTitleChange?(title)
    }

    // MARK: 周期聚合

    /// 历史部分读盘一次后缓存，每次刷新只把「今天」的实时数据叠上去。
    /// 这样即便存了一整年的日文件，1Hz 的界面刷新也不会反复读盘。
    private func rebuildPeriods(todayStats: DayStats) {
        let todayKey = todayStats.date
        if historyBuiltFor != todayKey {
            historyBuiltFor = todayKey
            var accumulator: [StatsPeriod: PeriodStats] = [:]
            for period in StatsPeriod.allCases { accumulator[period] = PeriodStats() }
            // 盘上那份「今天」最多比内存晚 20 秒，跳过它，免得重复计数
            for day in Store.shared.loadAll() where day.date != todayKey {
                for period in StatsPeriod.allCases where period.contains(day: day.date, today: todayKey) {
                    accumulator[period]?.add(day)
                }
            }
            historyPeriods = accumulator
        }

        var result: [StatsPeriod: PeriodStats] = [:]
        for period in StatsPeriod.allCases {
            var merged = historyPeriods[period] ?? PeriodStats()
            merged.add(todayStats)
            result[period] = merged
        }
        periods = result
    }

    /// 当前周期
    public var currentStats: PeriodStats {
        periods[statsPeriod] ?? PeriodStats()
    }

    public func stats(for period: StatsPeriod) -> PeriodStats {
        periods[period] ?? PeriodStats()
    }

    public var periodKicker: String {
        let month = String(today.date.prefix(7))
        let year = String(today.date.prefix(4))
        switch statsPeriod {
        case .today: return "Today · \(today.date)"
        case .month: return "This Month · \(month)"
        case .year: return "This Year · \(year)"
        case .all:
            let stats = currentStats
            guard let first = stats.firstDay, let last = stats.lastDay else { return "All Time" }
            return first == last ? "All Time · \(first)" : "All Time · \(first) → \(last)"
        }
    }

    public var periodHeadline: String {
        switch statsPeriod {
        case .today: return "今天敲了多少"
        case .month: return "这个月敲了多少"
        case .year: return "今年敲了多少"
        case .all: return "有史以来一共敲了多少"
        }
    }

    /// 概览页抬头那行小字
    public var periodSummary: String {
        let stats = currentStats
        guard stats.dayCount > 0 else {
            return "这个周期还没有记录 —— 敲几个键就开始了。"
        }
        switch statsPeriod {
        case .today:
            return "只统计次数与轨迹，不记录你打了什么。数据全部躺在本地。"
        case .month, .year:
            return "\(stats.dayCount) 天有记录 · 日均 \(Self.shortNumber(stats.dailyKeyAverage)) 键 · 只存次数，不存字符。"
        case .all:
            return "累计 \(stats.dayCount) 天有记录 · 日均 \(Self.shortNumber(stats.dailyKeyAverage)) 键 · 只存次数，不存字符。"
        }
    }

    // MARK: 动作

    public func togglePause() {
        engine.setPaused(!engine.isPaused)
        isPaused = engine.isPaused
    }

    public func requestPermission() {
        engine.requestInputAccess()
        refresh()
    }

    public func resetAll() {
        engine.resetAll()
        lastTrajectoryVersion = -1
        historyBuiltFor = ""      // 强制下次刷新重建历史聚合
        refresh()
    }

    public func exportCSV() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/A-Key-Stats-\(DayKey.of(Date())).csv")
        do {
            try Store.shared.exportCSV(to: url)
            return url
        } catch {
            return nil
        }
    }

    public func startReplay() {
        guard padTrajectory.count > 2 else { return }
        isReplaying = true
        replayProgress = 0
        replayTimer?.invalidate()
        replayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let span = max(self.padTrajectory.last!.t - self.padTrajectory.first!.t, 0.001)
                let duration = min(max(Double(span) / 8.0, 1.2), 12.0)   // 压缩到 1.2~12 秒
                self.replayProgress += (0.03 / duration)
                if self.replayProgress >= 1 {
                    self.replayProgress = 1
                    self.stopReplay()
                }
            }
        }
    }

    public func stopReplay() {
        replayTimer?.invalidate()
        replayTimer = nil
        isReplaying = false
    }

    // MARK: 派生数据

    public var layout: KeyboardLayout { KeyboardLayouts.layout(layoutID) }

    public var topKeys: [(label: String, count: Int)] {
        rankedKeys(today.keys)
    }

    /// 概览页用：当前周期（今天 / 本月 / 今年 / 全部）的排行
    public var currentTopKeys: [(label: String, count: Int)] {
        rankedKeys(currentStats.keys)
    }

    private func rankedKeys(_ keys: [String: Int]) -> [(label: String, count: Int)] {
        let layout = self.layout
        return keys
            .compactMap { code, count -> (String, Int)? in
                guard let label = layout.label(UInt16(code) ?? 0) else { return nil }
                return (label, count)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map { (label: $0.0, count: $0.1) }
    }

    /// 轨迹归一化里程换算成厘米（妙控板宽 16cm，取对角线近似）
    public var padTravelCentimeters: Double {
        today.padTravel * 20.0
    }

    /// 开发用：造一批假数据，方便离屏渲染对版式（不动真实存储）
    public func injectDemoData() {
        var day = today
        let hot: [(UInt16, Int)] = [(49, 5820), (36, 2410), (14, 1980), (1, 1620), (0, 1480),
                                    (2, 1310), (3, 1180), (51, 990), (48, 640), (55, 720),
                                    (4, 690), (5, 610), (17, 580), (16, 520), (12, 460),
                                    (46, 430), (38, 400), (40, 380), (37, 360), (41, 250),
                                    (123, 300), (124, 280), (126, 190), (125, 170), (53, 88)]
        for (code, count) in hot { day.keys[String(code)] = count }
        day.keys["50"] = 120
        day.hourly = [40, 10, 0, 0, 0, 0, 0, 30, 320, 980, 1420, 1180,
                      640, 210, 780, 1620, 1840, 1290, 860, 1120, 940, 560, 280, 90]
        day.clicks = ClickStats()
        day.clicks.left = 1842
        day.clicks.right = 96
        day.clicks.scroll = 2310
        day.activeSeconds = 5 * 3600 + 42 * 60

        // 几处高斯热点，模拟真实的「手一直在同一片区域磨」
        func blob(_ grid: inout HeatGrid, cx: Double, cy: Double, sigma: Double, count: Int) {
            for _ in 0..<count {
                let u1 = Double.random(in: 0.0001...1), u2 = Double.random(in: 0...1)
                let r = sigma * (-2 * log(u1)).squareRoot()
                let theta = 2 * Double.pi * u2
                grid.add(x: cx + r * cos(theta), y: cy + r * sin(theta))
            }
        }
        blob(&day.padGrid, cx: 0.30, cy: 0.42, sigma: 0.085, count: 9000)
        blob(&day.padGrid, cx: 0.58, cy: 0.70, sigma: 0.11, count: 12000)
        blob(&day.padGrid, cx: 0.78, cy: 0.30, sigma: 0.07, count: 5000)
        blob(&day.padGrid, cx: 0.50, cy: 0.55, sigma: 0.30, count: 3000)
        day.padContacts = 48210
        day.padMaxContact = 1.078
        day.padTravel = 96.4

        blob(&day.mouseGrid, cx: 0.30, cy: 0.20, sigma: 0.055, count: 5200)
        blob(&day.mouseGrid, cx: 0.70, cy: 0.22, sigma: 0.05, count: 2600)
        blob(&day.mouseGrid, cx: 0.50, cy: 0.34, sigma: 0.09, count: 3200)
        blob(&day.mouseGrid, cx: 0.50, cy: 0.62, sigma: 0.14, count: 2400)
        day.mouseContacts = 15230
        day.mouseTravel = 41.2
        today = day

        var trail: [TrajPoint] = []
        var t: Float = 100
        let strokes: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0.22, y: 0.30), CGPoint(x: 0.62, y: 0.46)),
            (CGPoint(x: 0.66, y: 0.52), CGPoint(x: 0.40, y: 0.74)),
            (CGPoint(x: 0.38, y: 0.62), CGPoint(x: 0.78, y: 0.40)),
            (CGPoint(x: 0.55, y: 0.25), CGPoint(x: 0.72, y: 0.68)),
            (CGPoint(x: 0.30, y: 0.50), CGPoint(x: 0.52, y: 0.34)),
        ]
        for (index, stroke) in strokes.enumerated() {
            let from = stroke.0, to = stroke.1
            let steps = 130
            for step in 0...steps {
                let k = Double(step) / Double(steps)
                let wiggle = sin(k * 9) * 0.012
                let px = from.x + (to.x - from.x) * k
                let py = from.y + (to.y - from.y) * k + wiggle
                t += 0.02
                trail.append(TrajPoint(t: t, x: Float(px), y: Float(py), id: UInt16(index)))
            }
            t += 1.5   // 抬手指的间隔
        }

        // 双指滚动：两根手指平行下滑，逐帧交替上报（正是以前被连成 Z 字的那种数据）
        for step in 0...120 {
            let k = Double(step) / 120
            let y = 0.80 - k * 0.45
            let wobble = sin(k * 12) * 0.004
            t += 0.01
            trail.append(TrajPoint(t: t, x: Float(0.42 + wobble), y: Float(y), id: 20))
            trail.append(TrajPoint(t: t, x: Float(0.56 + wobble), y: Float(y + 0.008), id: 21))
        }
        padTrajectory = trail
        mouseTrajectory = trail

        // 历史 14 天
        var days: [DayStats] = []
        let cal = Calendar.current
        for offset in stride(from: 13, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            var item = DayStats(date: DayKey.of(d))
            let base = [4200, 6100, 3800, 7200, 5400, 8900, 2600, 5100, 6400, 3300, 7600, 5800, 0, 6200][13 - offset]
            item.keys = ["49": base / 3, "36": base / 8, "14": base / 10]
            item.clicks.left = base / 4
            item.padTravel = Double(base) / 300
            item.activeSeconds = base / 2
            days.append(item)
        }
        if !days.isEmpty { days[days.count - 1] = today }
        for index in days.indices where index < days.count - 1 {
            days[index].padGrid = today.padGrid
            days[index].mouseGrid = today.mouseGrid
            days[index].padContacts = today.padContacts / 3
            days[index].mouseContacts = today.mouseContacts / 3
        }
        recentDays = days

        // 周期聚合：14 天真实相加，月/年/全部按倍数放大（只为对版式，不动真实存储）
        var base = PeriodStats()
        for item in days { base.add(item) }
        var todayOnly = PeriodStats()
        todayOnly.add(today)

        func backDated(_ days: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            return DayKey.of(date)
        }
        var monthPeriod = base
        monthPeriod.dayCount = max(monthPeriod.dayCount, 14)
        var yearPeriod = base.scaled(by: 21, days: 291)
        yearPeriod.firstDay = backDated(290)
        var allPeriod = base.scaled(by: 47, days: 654)
        allPeriod.firstDay = backDated(653)

        periods = [.today: todayOnly, .month: monthPeriod, .year: yearPeriod, .all: allPeriod]

        // 检测页的演示数据：一串正常按键 + 两次连键
        tester.reset()
        var clock = Date().addingTimeInterval(-30)
        let demoKeys: [(UInt16, Double)] = [(0, 0.09), (49, 0.07), (51, 0.05), (14, 0.08),
                                            (1, 0.06), (36, 0.11), (0, 0.07), (3, 0.05),
                                            (51, 0.04), (14, 0.06), (49, 0.08), (0, 0.06)]
        for (code, hold) in demoKeys {
            tester.handle(LiveInputEvent(kind: .keyDown, code: code, device: "BT3.0 Keyboard", at: clock), layout: layout)
            clock += hold
            tester.handle(LiveInputEvent(kind: .keyUp, code: code, device: "BT3.0 Keyboard", at: clock), layout: layout)
            clock += 0.13
        }
        // 造一颗「连键」：抬起 20ms 后又自己按下
        tester.handle(LiveInputEvent(kind: .keyDown, code: 1, device: "BT3.0 Keyboard", at: clock), layout: layout)
        clock += 0.05
        tester.handle(LiveInputEvent(kind: .keyUp, code: 1, device: "BT3.0 Keyboard", at: clock), layout: layout)
        clock += 0.02
        tester.handle(LiveInputEvent(kind: .keyDown, code: 1, device: "BT3.0 Keyboard", at: clock), layout: layout)
        clock += 0.06
        tester.handle(LiveInputEvent(kind: .keyUp, code: 1, device: "BT3.0 Keyboard", at: clock), layout: layout)

        for (index, button) in [0, 0, 0, 1, 0].enumerated() {
            tester.handle(LiveInputEvent(kind: .mouseDown, code: UInt16(button),
                                         device: "Apple Magic Mouse",
                                         at: Date().addingTimeInterval(-Double(6 - index) * 0.2)), layout: layout)
            tester.handle(LiveInputEvent(kind: .mouseUp, code: UInt16(button),
                                         device: "Apple Magic Mouse",
                                         at: Date().addingTimeInterval(-Double(6 - index) * 0.2 + 0.06)), layout: layout)
        }
        tester.flushNow()   // 造完立刻出图，不等 60Hz 的节流
    }

    public static func shortNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }
}
