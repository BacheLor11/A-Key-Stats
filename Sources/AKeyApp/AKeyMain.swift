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
        print("键盘设备 : \(tap.keyboardNames.isEmpty ? "（空，多半是没授权）" : tap.keyboardNames.joined(separator: "、"))")
        print("鼠标设备 : \(tap.mouseNames.isEmpty ? "（空）" : tap.mouseNames.joined(separator: "、"))")

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
