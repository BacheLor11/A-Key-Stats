import AppKit
import SwiftUI
import AVFoundation
import AKeyKit
import AKeyUI
import AKitStatusKit

@main
@MainActor
struct AKeyStatsMain {
    static func main() {
        let args = CommandLine.arguments

        // 开发用：离屏渲染页面，不用开窗就能对版式
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let path = args[index + 1]
            let page = (index + 2 < args.count) ? args[index + 2] : "dashboard"
            Snapshot.render(to: path, pageName: page)
            return
        }

        // 开发用：不开窗，打印权限 / 设备 / 目录
        if args.contains("--selftest") {
            SelfTest.run()
            return
        }

        // 开发用：实时看触控板有没有数据（摸一下板子就知道通不通）
        if let index = args.firstIndex(of: "--livepad") {
            let seconds = Double(args[safe: index + 1] ?? "10") ?? 10
            LivePad.run(seconds: seconds)
            return
        }

        // 开发用：敲键对拍，验证 HID usage → 虚拟键码的映射对不对
        if let index = args.firstIndex(of: "--keylog") {
            let seconds = Double(args[safe: index + 1] ?? "20") ?? 20
            KeyLog.run(seconds: seconds)
            return
        }

        // 开发用：给 --keytap 当发键用的子进程
        if args.contains("--postkey") {
            KeyTapCLI.postKey()
            return
        }

        // 开发用：一次性体检（签名身份 / 权限 / 设备 / 是否能收到键）
        if let index = args.firstIndex(of: "--keyperm") {
            let seconds = Double(args[safe: index + 1] ?? "8") ?? 8
            KeyPermCLI.run(seconds: seconds)
            return
        }

        // 开发用：验证事件层兜底能收到按键（自己发一个 Control 按下，不打扰前台）
        if let index = args.firstIndex(of: "--keytap") {
            let seconds = Double(args[safe: index + 1] ?? "4") ?? 4
            KeyTapCLI.run(seconds: seconds)
            return
        }

        // 开发用：把外设信号跑一遍判定，看是哪台设备、差多少到门槛
        if let index = args.firstIndex(of: "--hw") {
            let days = Int(args[safe: index + 1] ?? "14") ?? 14
            HardwareCLI.run(days: days)
            return
        }

        // 开发用：判定器自测（喂合成事件，不碰真实数据）
        if args.contains("--hwtest") {
            HardwareCLI.selfTest()
            return
        }

        // 开发用：确认鼠标位移到底有没有从 IOHID 出来（跳变检测的前提）
        if let index = args.firstIndex(of: "--ptr") {
            let seconds = Double(args[safe: index + 1] ?? "8") ?? 8
            PointerCLI.run(seconds: seconds)
            return
        }

        // 开发用：不开窗，直接把全部触控板轨迹导成 CSV（验证流式解码 / 格式）
        if let index = args.firstIndex(of: "--export-traj") {
            let path = args[safe: index + 1] ?? "/tmp/aks-trajectory.csv"
            TrajectoryCLI.run(to: path)
            return
        }

        // 开发用：直接渲一条轨迹视频，顺带抽几帧 PNG 对版式
        if let index = args.firstIndex(of: "--video") {
            let path = args[safe: index + 1] ?? "/tmp/aks-trajectory.mp4"
            let day = args[safe: index + 2]
            let seconds = args[safe: index + 3].flatMap(Double.init)
            VideoCLI.run(to: path, day: day, seconds: seconds)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

// MARK: - 委托

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var window: NSWindow?
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupWindow()
        connectAKit()

        state.onMenuBarTitleChange = { [weak self] title in
            self?.applyMenuBarTitle(title)
        }
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        Engine.shared.flush()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "A-Key-Stats")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.attributedTitle = Self.title("— 键")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private static func title(_ text: String) -> NSAttributedString {
        NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ])
    }

    private func applyMenuBarTitle(_ text: String) {
        statusItem?.button?.attributedTitle = Self.title(text)
        AKHubClient.shared.pushStatus("今日 \(text)")
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
        if isRight {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(item("打开 A-Key-Stats", #selector(openWindowAction)))
        menu.addItem(item(state.isPaused ? "继续记录" : "暂停记录", #selector(togglePauseAction)))
        menu.addItem(.separator())
        menu.addItem(item("键盘热力", #selector(openKeyboardAction)))
        menu.addItem(item("触控板", #selector(openTrackpadAction)))
        menu.addItem(item("鼠标", #selector(openMouseAction)))
        menu.addItem(item("按键检测", #selector(openTesterAction)))
        menu.addItem(item("设置…", #selector(openSettingsAction)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quitAction)))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openWindowAction() { showWindow() }
    @objc private func openKeyboardAction() { state.page = .keyboard; showWindow() }
    @objc private func openTrackpadAction() { state.page = .trackpad; showWindow() }
    @objc private func openMouseAction() { state.page = .mouse; showWindow() }
    @objc private func openTesterAction() { state.page = .tester; showWindow() }
    @objc private func openSettingsAction() { state.page = .settings; showWindow() }
    @objc private func togglePauseAction() { state.togglePause() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    // MARK: 面板

    private func makePanel() -> NSPanel {
        let view = PanelView(
            onOpen: { [weak self] in self?.hidePanel(); self?.showWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(state)

        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 346, height: max(size.height, 280)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        return p
    }

    private func togglePanel() {
        if let panel, panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            let height = max(host.fittingSize.height, 280)
            var frame = panel.frame
            let top = frame.maxY
            frame.size.height = height
            frame.origin.y = top - height
            panel.setFrame(frame, display: true)
        }
        positionPanel(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        let size = panel.frame.size
        var origin = NSPoint.zero
        if let button = statusItem?.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 4)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.maxY - size.height - 40)
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, origin.y)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: 主窗口

    private func setupWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "A-Key-Stats"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = AKSWindowColor.dynamic
        w.minSize = NSSize(width: 1000, height: 640)
        w.contentView = NSHostingView(rootView: RootView().environmentObject(state))
        w.setFrameAutosaveName("AKeyStatsMainWindow")
        w.center()
        window = w
    }

    private func showWindow() {
        if window == nil { setupWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: A-Kit

    private func connectAKit() {
        AKHubClient.shared.onConnectionChange = { [weak self] connected in
            self?.statusItem?.isVisible = !connected
        }
        AKHubClient.shared.onInvoke = { [weak self] itemId in
            guard let self else { return }
            switch itemId {
            case "open": self.showWindow()
            case "keyboard": self.state.page = .keyboard; self.showWindow()
            case "trackpad": self.state.page = .trackpad; self.showWindow()
            case "mouse": self.state.page = .mouse; self.showWindow()
            case "tester": self.state.page = .tester; self.showWindow()
            case "pause": self.state.togglePause()
            case "settings": self.state.page = .settings; self.showWindow()
            default: break
            }
        }
        AKHubClient.shared.start(info: AKToolInfo(
            bundleId: "com.aibao.AKeyStats",
            name: "A-Key-Stats",
            version: AKSBundle.version,
            status: "记录中",
            menu: [
                AKMenuItem(id: "open", title: "打开 A-Key-Stats"),
                AKMenuItem(id: "keyboard", title: "键盘热力"),
                AKMenuItem(id: "trackpad", title: "触控板"),
                AKMenuItem(id: "mouse", title: "鼠标"),
                AKMenuItem(id: "tester", title: "按键检测"),
                AKMenuItem.separator("sep1"),
                AKMenuItem(id: "pause", title: "暂停记录", kind: .toggle, checked: false),
                AKMenuItem(id: "settings", title: "设置…"),
            ]))
    }
}

// MARK: - 外设信号自检

/// 把磁盘上的信号跑一遍判定：每台设备收了多少样本、各指标多少次、
/// 离门槛还差多少。排查「是不是硬件有毛病」时先看这个。
@MainActor
enum HardwareCLI {
    static func run(days: Int) {
        _ = NSApplication.shared
        let keys = Array(Store.shared.availableDays().prefix(max(1, days)))
        let list = keys.compactMap { Store.shared.load(day: $0) }
        let today = DayKey.of(Date())

        print("A-Key-Stats 外设信号 · 磁盘上的最近 \(list.count) 天（最多落后 20 秒）")
        if let newest = list.first?.date, let oldest = list.last?.date {
            print("范围: \(oldest) → \(newest)" + (newest == today ? "" : " · 今天还没落盘"))
        }

        let aggregates = HardwareWatch.aggregate(list)
        guard !aggregates.isEmpty else {
            print("还没有任何信号 —— 0.5.0 才开始记录，正常用一天再来看。")
            exit(0)
        }
        for agg in aggregates {
            print("\n\(agg.kind.title) · \(agg.device)")
            print("  样本 \(agg.samples) 次 · \(agg.dayCount) 天有数据")
            for metric in agg.metrics.keys.sorted() {
                let name = metric.padding(toLength: 7, withPad: " ", startingAt: 0)
                let rate = String(format: "%.2f", agg.rate(metric))
                print("  \(name) \(agg.value(metric)) 次 · 每千次 \(rate) · \(agg.metricDays[metric] ?? 0) 天")
            }
        }

        let findings = HardwareWatch.findings(list)
        print("\n判定:")
        if findings.isEmpty { print("  都还没到门槛（样本不足也算没到）") }
        for finding in findings {
            print("  [\(finding.level.rawValue)] \(finding.headline)")
            print("    \(finding.detail)")
            for row in finding.rows { print("    · \(row.label): \(row.value)") }
            print("    → \(finding.advice)")
        }
        exit(0)
    }

    /// 合成事件自测：判定器写错一个比较符号，界面上是看不出来的。
    static func selfTest() {
        var failures: [String] = []

        func check(_ name: String, expect: Int, _ actual: Int) {
            if actual == expect {
                print("  ✓ \(name) = \(actual)")
            } else {
                print("  ✗ \(name) = \(actual)，应为 \(expect)")
                failures.append(name)
            }
        }

        func value(_ probe: HardwareProbe, _ kind: PeripheralKind, _ device: String, _ metric: String) -> Int {
            probe.day.devices[HardwareDay.key(kind: kind, name: device)]?.value(metric) ?? 0
        }

        // 1. 同一颗键 45ms 内两次 = 重复触发
        let k1 = HardwareProbe()
        k1.keyDown(0, device: "K")
        Thread.sleep(forTimeInterval: 0.045)
        k1.keyDown(0, device: "K")
        check("键盘重复触发", expect: 1, value(k1, .keyboard, "K", Metric.keyChatter))

        // 2. 打字后 120ms 内回删 = 立刻回删
        let k2 = HardwareProbe()
        k2.keyDown(0, device: "K")
        Thread.sleep(forTimeInterval: 0.12)
        k2.keyDown(51, device: "K")
        check("打字后立刻回删", expect: 1, value(k2, .keyboard, "K", Metric.keyFix))

        // 3. 连删三次再打字 = 重打
        let k3 = HardwareProbe()
        k3.keyDown(0, device: "K")
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.08)
            k3.keyDown(51, device: "K")
        }
        Thread.sleep(forTimeInterval: 0.10)
        k3.keyDown(0, device: "K")
        check("连删后重打", expect: 1, value(k3, .keyboard, "K", Metric.keyRewrite))

        // 4. 鼠标：连续小位移后突然一个大跳，下一帧恢复正常
        let m1 = HardwareProbe()
        for _ in 0..<12 { m1.pointer(dx: 4, dy: 3, device: "M") }
        m1.pointer(dx: 420, dy: 0, device: "M")
        m1.pointer(dx: 4, dy: 3, device: "M")
        check("鼠标跳点", expect: 1, value(m1, .mouse, "M", Metric.mouseJump))

        // 4b. 快速甩动是「连续」大位移，不该当成跳点
        let m3 = HardwareProbe()
        for _ in 0..<12 { m3.pointer(dx: 5, dy: 2, device: "M") }
        for _ in 0..<6 { m3.pointer(dx: 300, dy: 120, device: "M") }
        for _ in 0..<3 { m3.pointer(dx: 5, dy: 2, device: "M") }
        check("快速甩动不算跳点", expect: 0, value(m3, .mouse, "M", Metric.mouseJump))

        // 5. 鼠标：连续移动中停 200ms 再继续 = 断流
        let m2 = HardwareProbe()
        for _ in 0..<8 { m2.pointer(dx: 3, dy: 2, device: "M") }
        Thread.sleep(forTimeInterval: 0.20)
        m2.pointer(dx: 3, dy: 2, device: "M")
        check("鼠标断流", expect: 1, value(m2, .mouse, "M", Metric.mouseStall))

        // 6. 触控板：单帧跳到板子另一头，下一帧继续正常移动
        let t1 = HardwareProbe()
        for i in 0..<10 {
            t1.frame(device: "T", primary: (0.40 + Double(i) * 0.005, 0.50))
        }
        t1.frame(device: "T", primary: (0.78, 0.42))
        t1.frame(device: "T", primary: (0.785, 0.42))
        check("触控板单帧跳变", expect: 1, value(t1, .trackpad, "T", Metric.padJump))

        // 6b. 快速滑动是连续大位移，不该当成跳变
        let t3 = HardwareProbe()
        for i in 0..<10 {
            t3.frame(device: "T", primary: (0.20 + Double(i) * 0.005, 0.50))
        }
        for i in 0..<6 {
            t3.frame(device: "T", primary: (0.30 + Double(i) * 0.06, 0.50))
        }
        t3.frame(device: "T", primary: (0.66, 0.50))
        check("快速滑动不算跳变", expect: 0, value(t3, .trackpad, "T", Metric.padJump))

        // 7. 触控板：手指没抬，报点断了 200ms
        let t2 = HardwareProbe()
        for i in 0..<8 {
            t2.frame(device: "T", primary: (0.40 + Double(i) * 0.005, 0.50))
        }
        Thread.sleep(forTimeInterval: 0.20)
        t2.frame(device: "T", primary: (0.45, 0.50))
        check("触控板报点中断", expect: 1, value(t2, .trackpad, "T", Metric.padStall))

        // 8. 判定门槛：样本不足时不该出结论
        var day = DayStats(date: "2026-01-01")
        var bucket = DeviceSignals(kind: .mouse, name: "M")
        bucket.samples = 100
        bucket.metrics[Metric.mouseJump] = 50
        day.hardware.devices[HardwareDay.key(kind: .mouse, name: "M")] = bucket
        check("样本不足不判定", expect: 0, HardwareWatch.findings([day]).count)

        // 9. 编解码往返：hardware 字段要能存能读
        if let data = try? JSONEncoder().encode(day),
           let back = try? JSONDecoder().decode(DayStats.self, from: data),
           back.hardware.devices.count == 1 {
            print("  ✓ 编解码往返")
        } else {
            print("  ✗ 编解码往返")
            failures.append("编解码往返")
        }

        // 10. 老数据（0.4.x 没有 hardware 字段）要能读
        let old = #"{"date":"2026-01-01","keys":{"0":3},"hourly":[1],"clicks":{"left":2}}"#.data(using: .utf8)!
        if let decoded = try? JSONDecoder().decode(DayStats.self, from: old),
           decoded.keyTotal == 3, decoded.hardware.devices.isEmpty, decoded.hourly.count == 24 {
            print("  ✓ 老数据兼容")
        } else {
            print("  ✗ 老数据兼容")
            failures.append("老数据兼容")
        }

        print(failures.isEmpty ? "\n全部通过" : "\n失败 \(failures.count) 项：\(failures.joined(separator: "、"))")
        exit(failures.isEmpty ? 0 : 1)
    }
}

// MARK: - 指针位移自检

/// 确认鼠标的位移报文到底有没有从 IOHID 出来。
/// 跳变检测全靠这一路，如果这里一直 0，说明这只鼠标的位移不走 HID（蓝牙私有通道）。
@MainActor
enum PointerCLI {
    static func run(seconds: Double) {
        _ = NSApplication.shared
        let tap = InputTap()
        var counts: [String: Int] = [:]
        var total = 0
        tap.onPointer = { _, _, name in
            counts[name, default: 0] += 1
            total += 1
        }
        let ok = tap.start()
        print("指针链路: \(ok ? "已打开" : "打不开")")
        print("可见鼠标设备: \(tap.mouseNames.isEmpty ? "（空）" : tap.mouseNames.joined(separator: "、"))")

        let devices = tap.pointerDevices()
        if devices.isEmpty {
            print("⚠️  没有带 X/Y 位移元素的指针设备 —— 这台机器的鼠标位移不走 IOHID，跳变检测拿不到数据")
        } else {
            for device in devices {
                print("  \(device.name) · X/Y 位移元素\(device.hasAxes ? "有" : "没有（只报按键）")")
            }
        }

        print("请移动鼠标 \(Int(seconds)) 秒…")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        tap.stop()

        if counts.isEmpty {
            print("没收到任何位移报文")
        } else {
            for (name, count) in counts.sorted(by: { $0.value > $1.value }) {
                print("  \(name): \(count) 条")
            }
            print(String(format: "合计 %d 条 · %.0f 条/秒", total, Double(total) / seconds))
        }
        exit(counts.isEmpty ? 5 : 0)
    }
}

// MARK: - 离屏渲染（开发自检）

@MainActor
enum Snapshot {
    static func render(to path: String, pageName: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["AKS_DARK"] == "1" ? .darkAqua : .aqua)

        let state = AppState()
        state.page = AppState.Page(rawValue: pageName) ?? .dashboard
        if ProcessInfo.processInfo.environment["AKS_DEMO"] == "1" {
            state.injectDemoData()
            state.frozen = true
        }
        if let env = ProcessInfo.processInfo.environment["AKS_LAYOUT"],
           let layout = KeyboardLayoutID(rawValue: env) {
            state.persistPreferences = false
            state.layoutID = layout
        }
        if let env = ProcessInfo.processInfo.environment["AKS_OVERVIEW"],
           let panels = AppState.OverviewPanels(rawValue: env) {
            state.persistPreferences = false
            state.overviewPanels = panels
        }
        if let env = ProcessInfo.processInfo.environment["AKS_PERIOD"],
           let period = StatsPeriod(rawValue: env) {
            state.persistPreferences = false
            state.statsPeriod = period
        }
        // 开发自检：伪造键盘体检状态，对提示条文案/版式用
        if let env = ProcessInfo.processInfo.environment["AKS_KEY"] {
            let keyboards = env == "hidden" ? [] : ["Apple Internal Keyboard / Trackpad"]
            let healthState: KeyboardHealth.State = {
                switch env {
                case "hidden": return .hidden
                case "taponly": return .tapOnly
                default: return .noAccess
                }
            }()
            state.injectKeyHealth(KeyboardHealth(state: healthState,
                                                 access: env == "hidden" || env == "taponly" ? .granted : .denied,
                                                 keyboards: keyboards,
                                                 hidEvents: 0,
                                                 tapEvents: env == "taponly" ? 12 : 0,
                                                 lastKeyAt: nil,
                                                 managerOpen: true))
        }

        // 开发自检：伪造外设信号提示，对三个页面的版式
        if let env = ProcessInfo.processInfo.environment["AKS_HW"],
           let kind = PeripheralKind(rawValue: env) {
            state.injectHardwareDemo(kind)
        }

        let isPanel = pageName == "panel"
        let isSheet = pageName == "videosheet"
        let shotHeight = CGFloat(Double(ProcessInfo.processInfo.environment["AKS_H"] ?? "") ?? 800)
        let shotWidth: CGFloat = 1140
        let root: AnyView
        if isPanel {
            root = AnyView(PanelView(onOpen: {}, onQuit: {}).environmentObject(state).frame(width: 346))
        } else if isSheet {
            root = AnyView(TrajectoryVideoSheetPreview().environmentObject(state))
        } else {
            root = AnyView(RootView().environmentObject(state).frame(width: shotWidth, height: shotHeight))
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0,
                            width: isPanel ? 346 : (isSheet ? 476 : shotWidth),
                            height: isPanel ? 360 : (isSheet ? 400 : shotHeight))
        host.layoutSubtreeIfNeeded()

        // 等引擎第一轮采样（也等触控板设备枚举）
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if !state.padDevices.isEmpty || Date().timeIntervalSince1970 > deadline.timeIntervalSince1970 - 3 {
                break
            }
        }
        host.layoutSubtreeIfNeeded()

        // 开发自检：重复光栅化，量一帧的真实成本（AKS_FRAMES=50）
        if let raw = ProcessInfo.processInfo.environment["AKS_FRAMES"], let count = Int(raw), count > 0,
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            let start = Date()
            for _ in 0..<count { host.cacheDisplay(in: host.bounds, to: rep) }
            let per = Date().timeIntervalSince(start) / Double(count) * 1000
            print(String(format: "frame · %.2f ms / 帧（%d 帧平均）", per, count))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("snapshot: 无法创建位图")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("snapshot → \(path) · 按键 \(state.today.keyTotal) · 设备 \(state.padDevices.count)")
        }
        exit(0)
    }
}

// MARK: - 实时触控板观测

@MainActor
enum LivePad {
    static func run(seconds: Double) {
        _ = NSApplication.shared
        let tap = PadTap()
        var frames = 0
        var contacts = 0
        var maxSize: Double = 0
        tap.onFrame = { _, list in
            frames += 1
            contacts += list.count
            for c in list { maxSize = max(maxSize, c.size) }
        }
        guard tap.start() else {
            print("❌ 触控板采集启动失败")
            exit(3)
        }
        print("▶️  盯着触控板 \(Int(seconds)) 秒，现在摸一下板子 / 画个圈…")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        tap.stop()
        print(String(format: "帧数 %d · 接触点 %d · 峰值面积 %.3f", frames, contacts, maxSize))
        exit(frames > 0 ? 0 : 6)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}

// MARK: - 事件层兜底自检
//
@MainActor
enum KeyPermCLI {
    static func run(seconds: Double) {
        _ = NSApplication.shared
        let info = SigningInfo.current()

        print("A-Key-Stats \(AKSBundle.version) 键盘体检")
        print("  应用路径  : \(info.pathNote)")
        print("  BundleID  : \(info.bundleID)")
        print("  签名      : \(info.identity)\(info.teamID.map { " · Team \($0)" } ?? "")")
        print("  其他副本  : \(info.otherCopies.isEmpty ? "无" : info.otherCopies.joined(separator: "、"))")
        if let note = SigningVerdict.note(info) { print("  ⚠️  \(note)") }
        print("  输入监控  : \(accessText(InputTap.access()))")
        print("  事件层权限: \(CGPreflightListenEventAccess() ? "有" : "无")")

        let input = InputTap()
        var downs: [(code: UInt16, device: String)] = []
        input.onKeyDown = { code, device in downs.append((code, device)) }
        let opened = input.start()
        print("  IOHID open: \(opened ? "成功" : "失败")")
        print("  键盘设备  : \(input.keyboardNames.isEmpty ? "（空）" : input.keyboardNames.joined(separator: "、"))")
        print("  鼠标设备  : \(input.mouseNames.isEmpty ? "（空）" : input.mouseNames.joined(separator: "、"))")
        print("")
        print("请在这 \(Int(seconds)) 秒里敲几下键盘（Esc 也算）…")

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        input.stop()

        print("")
        if downs.isEmpty {
            print("  收到按键  : 0 次 · HID 事件 \(input.receivedEvents)")
            print("❌ HID 链路一条都没收到。")
            if InputTap.access() != .granted {
                print("   输入监控是 denied —— 去系统设置 → 隐私与安全性 → 输入监控，")
                print("   把 A-Key-Stats 用「−」删掉，再启动 app 重新授权一次。")
            } else {
                print("   权限是 granted 却收不到键：检查键盘是否真的接在这台机器上。")
            }
            print("   提示：从终端直接跑时，系统有可能把权限算在终端头上，以 app 内「复制诊断」为准。")
            exit(6)
        }
        let sample = downs.prefix(12)
            .map { String(format: "0x%02X", $0.code) + "(\($0.device))" }
            .joined(separator: " ")
        print("  收到按键  : \(downs.count) 次 · HID 事件 \(input.receivedEvents)")
        print("  样例      : \(sample)")
        print("✅ HID 链路正常")
        exit(0)
    }

    private static func accessText(_ access: InputTap.Access) -> String {
        switch access {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unknown: return "unknown"
        }
    }
}

// 键盘被系统藏起来（或按键根本不是本机键盘发的）时，只有 CGEventTap 能看见。
// 这里自己发一个 Control 按下/抬起，验证回调真的会被调用、键码取得对，
// 不往输入焦点里塞可见字符。

@MainActor
enum KeyTapCLI {
    static func run(seconds: Double) {
        _ = NSApplication.shared
        let tap = KeyTap()
        var downs: [UInt16] = []
        var ups: [UInt16] = []
        tap.onKeyDown = { downs.append($0) }
        tap.onKeyUp = { ups.append($0) }

        guard tap.start() else {
            print("❌ 事件层监听挂不上（输入监控没给到本进程）")
            exit(3)
        }
        print("▶️  事件层监听已启动 ✓  监听 \(Int(seconds)) 秒")
        print("   监听权限 \(CGPreflightListenEventAccess() ? "✓" : "✗") · 辅助功能 \(AXIsProcessTrusted() ? "✓" : "✗")")

        // 同一个进程往事件层塞的键，系统不会再回灌给它自己的 tap，
        // 所以必须另起一个进程去发 —— 这样才是真的「别人按的键我方能不能听见」
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--postkey"]
        try? child.run()
        print("   已派生 #\(child.processIdentifier) 在 1 秒后发一个 Control 按下/抬起（不出字符）")

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        tap.stop()
        print(String(format: "down %d 条 · up %d 条 · 键码 %@", downs.count, ups.count,
                     downs.isEmpty ? "—" : downs.map { String(format: "0x%02X", $0) }.joined(separator: ",")))
        if downs.isEmpty {
            print("   （0 条不一定代表监听坏了：发键那一步在沙箱/无辅助功能的进程里会被静默拦掉，")
            print("     真正的判据是真键盘敲一下 —— app 里看顶部提示条是「已兜底」还是「看不到键盘」）")
        }
        exit(downs.isEmpty ? 6 : 0)
    }

    /// 子进程：发一个 Control 按下/抬起就走
    static func postKey() {
        Thread.sleep(forTimeInterval: 1.0)
        let source = CGEventSource(stateID: .hidSystemState)
        let key: CGKeyCode = 0x3B          // kVK_Control
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        exit(0)
    }
}

// MARK: - 键码对拍
//
// 同一次按键，左边是 HID 原始 usage + 映射表算出的虚拟键码，右边是系统通过
// NSEvent 给出的真实虚拟键码。两个一致才说明采集和界面画的是同一个键。

@MainActor
enum TrajectoryCLI {
    static func run(to path: String) {
        let today = DayKey.of(Date())
        let days = TrajectoryExport.dates(for: .all, today: today)
        print("▶️  轨迹导出：\(days.count) 天 → \(path)")
        do {
            let outcome = try TrajectoryExport.writeCSV(days: days, kind: .pad,
                                                        to: URL(fileURLWithPath: path))
            print("✅ \(outcome.points) 点 · \(outcome.days) 天 · \(outcome.bytes) 字节")
        } catch {
            print("❌ \(error.localizedDescription)")
            exit(3)
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<TrajectoryVideo.Outcome, Error>?
    let semaphore = DispatchSemaphore(value: 0)
}

private final class StepBox: @unchecked Sendable {
    var value = -1
}

/// 开发用：渲一条轨迹回放视频，再抽几帧 PNG 出来对版式
enum VideoCLI {
    static func run(to path: String, day: String?, seconds: Double?) {
        let target = day ?? DayKey.of(Date())
        var config = TrajectoryVideo.Config()
        config.duration = seconds
        config.dark = ProcessInfo.processInfo.environment["AKS_DARK"] == "1"

        let url = URL(fileURLWithPath: path)
        let length = seconds.map { String(format: "%.1f 秒", $0) } ?? "自动"
        print("▶️  轨迹回放：\(target) → \(path)  \(config.width)×\(config.height) @\(config.fps)fps  \(length)")

        let started = Date()
        let box = ResultBox()
        let step = StepBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outcome = try TrajectoryVideo.render(day: target, to: url, config: config) { progress in
                    let value = Int(progress * 10)
                    if value != step.value {
                        step.value = value
                        print("   \(value * 10)%")
                    }
                }
                box.result = .success(outcome)
            } catch {
                box.result = .failure(error)
            }
            box.semaphore.signal()
        }
        box.semaphore.wait()

        switch box.result {
        case .success(let outcome):
            let cost = Date().timeIntervalSince(started)
            let duration = String(format: "%.2f", outcome.seconds)
                + (outcome.automaticDuration ? "（跟 App 回放一致）" : "")
            print("✅ \(outcome.frames) 帧 · \(duration) 秒 · \(outcome.points) 点 · \(outcome.bytes / 1024) KB")
            print("   行程 \(TrajectoryVideo.meters(outcome.travelCM)) · 渲染耗时 \(String(format: "%.1f", cost)) 秒")
            extractStills(from: url)
        case .failure(let error):
            print("❌ \(error.localizedDescription)")
            exit(3)
        case .none:
            print("❌ 没有结果")
            exit(3)
        }
    }

    /// 用 AVAssetImageGenerator 从成片里抽帧，确认编码后的实际画面
    private static func extractStills(from url: URL) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let total = asset.duration.seconds
        guard total > 0 else { return }

        let marks: [Double] = [0.10, 0.35, 0.62, 0.85, 0.99]
        for mark in marks {
            let time = CMTime(seconds: total * mark, preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let out = "/tmp/aks-video-\(Int(mark * 100)).png"
            try? data.write(to: URL(fileURLWithPath: out))
            print("   🖼  \(out)")
        }
    }
}

@MainActor
enum KeyLog {
    static func run(seconds: Double) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let layout = KeyboardLayout.build(.ansiCompact)
        let tap = InputTap()
        var pending: [(usage: UInt16, vk: UInt16?, at: Date)] = []
        var pairs = 0
        var mismatches = 0
        var ignored = 0

        tap.onRawKey = { usage, vk, device in
            pending.append((usage, vk, Date()))
            let name = vk.flatMap { layout.label($0) } ?? "—"
            let mapped = vk.map { String(format: "0x%02X", $0) } ?? "无映射"
            print(String(format: "  HID 0x%02X → %@ (%@)   via %@", usage, mapped, name, device))
        }
        tap.onDuplicateKey = { usage, _ in
            print(String(format: "     ⚠️ 重复上报：usage 0x%02X 在 35ms 内又来了第二次（已去重）", usage))
        }

        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let systemVK = UInt16(event.keyCode)
            pending.removeAll { Date().timeIntervalSince($0.at) > 1.0 }
            if let index = pending.firstIndex(where: { $0.vk == systemVK }) {
                pending.remove(at: index)
                pairs += 1
                print("     ✓ 与系统一致  vk 0x\(String(format: "%02X", systemVK))")
            } else if let index = pending.indices.last {
                let guess = pending.remove(at: index)
                mismatches += 1
                print(String(format: "     ❌ 不一致：系统 vk 0x%02X，映射算出 0x%02X —— usage 0x%02X 的对应关系要改",
                             systemVK, guess.vk ?? 0xFFFF, guess.usage))
            } else {
                ignored += 1
            }
        }

        guard tap.start() else {
            print("❌ 采集启动失败（多半是输入监控没授权）")
            exit(3)
        }
        print("▶️  \(Int(seconds)) 秒内随手敲几个键：A、空格、回车、Backspace、Shift、数字 1、方向键")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        tap.stop()
        print("—— 对拍结束：一致 \(pairs) · 不一致 \(mismatches) · 未配对 \(ignored) ——")
        if !tap.unmappedUsages.isEmpty {
            let list = tap.unmappedUsages.map { String(format: "0x%02X×%d", $0.key, $0.value) }.sorted()
            print("未识别 usage：\(list.joined(separator: " "))")
        }
        exit(mismatches == 0 ? 0 : 7)
    }
}

// MARK: - 自检

@MainActor
enum SelfTest {
    static func run() {
        print("=== A-Key-Stats 自检 ===")
        print("数据目录 : \(Store.shared.root.path)")

        switch InputTap.access() {
        case .granted: print("输入监控 : ✅ 已授权")
        case .denied: print("输入监控 : ❌ 被拒绝")
        case .unknown: print("输入监控 : ⚠️ 未授权（计数拿不到数据）")
        }

        let tap = InputTap()
        _ = tap.start()
        tap.refreshDevices()
        print("键盘设备 : \(tap.keyboardNames.isEmpty ? "（空，可能是键盘不在本机 / 未授权）" : tap.keyboardNames.joined(separator: "、"))")
        print("鼠标设备 : \(tap.mouseNames.isEmpty ? "（空）" : tap.mouseNames.joined(separator: "、"))")

        // 键盘设备为空时，事件层兜底能不能挂上，决定了还有没有救
        let keyTap = KeyTap()
        if keyTap.start() {
            print("事件层监听 : ✅ 可用（键盘被系统藏起来时靠它兜底）")
            keyTap.stop()
        } else {
            print("事件层监听 : ❌ 不可用（输入监控没给到本进程）")
        }

        let devices = PadTap.describeDevices()
        print("多点触控 : \(devices.isEmpty ? "（空）" : "")")
        for line in devices { print("           · \(line)") }

        let pad = PadTap()
        if pad.start() {
            print("触控板采集 : ✅ 已启动，设备 \(pad.devices.count) 个")
            for device in pad.devices {
                print("           · \(device.kind.rawValue) · \(device.displayName) · \(device.locationID)")
            }
            pad.stop()
        } else {
            print("触控板采集 : ❌ 启动失败（私有框架可能变了）")
        }

        let day = Engine.shared.snapshot()
        print("今日统计 : 按键 \(day.keyTotal) · 点击 \(day.clickTotal) · 触控帧 \(day.padContacts)")
        checkTrajectory()
        exit(0)
    }

    /// 轨迹格式往返 + v1 老文件升级，别等用户发现轨迹画歪了才回头查
    private static func checkTrajectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-traj-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("probe.pad.bin")

        func v1Record(_ t: Float, _ x: Float, _ y: Float) -> Data {
            var d = Data()
            withUnsafeBytes(of: t.bitPattern.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(x * 65535).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(y * 65535).littleEndian) { d.append(contentsOf: $0) }
            return d
        }
        var legacy = Data([0x41, 0x4B, 0x53, 0x54, 0x01, 0x00, 0x00, 0x00])
        legacy.append(v1Record(1, 0.1, 0.1))
        legacy.append(v1Record(2, 0.2, 0.2))
        try? legacy.write(to: url)

        let writer = TrajectoryWriter(url: url)
        writer.append(t: 3, x: 0.3, y: 0.3, id: 7)
        writer.append(t: 4, x: 0.4, y: 0.4, id: 7)
        writer.append(t: 4, x: 0.7, y: 0.7, id: 8)
        writer.close()

        let points = TrajectoryWriter.read(url: url)
        let ids = Set(points.map(\.id)).sorted()
        let ok = points.count == 5 && ids == [0, 7, 8]
        print("轨迹往返 : \(ok ? "✅" : "❌") \(points.count) 点 · 手指 id \(ids)")
    }
}
