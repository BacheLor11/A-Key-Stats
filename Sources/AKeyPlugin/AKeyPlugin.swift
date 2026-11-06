import AppKit
import SwiftUI
import AKeyKit
import AKeyUI
import AKitPluginKit

/// A-Key-Stats 的插件壳。
///
/// 它**不重画任何界面**：面板就是独立运行时那张 `PanelView`，
/// 整页就是独立运行时那个 `RootView`。这样两边永远一致，
/// 不会出现「A-Kit 里一份菜单、独立 app 里另一份，改一处漏一处」。
///
/// 数据也共用同一份：`Store` 的路径是写死的
/// `~/Library/Application Support/A-Key-Stats/`，偏好走 `AKSPrefs` 的
/// 显式 suite（`com.aibao.AKeyStats`），所以两种形态读写完全一致。
///
/// 权限要单独说一句：TCC 认的是**进程**，不是 dylib。作为插件跑在 A-Kit 里时，
/// 「输入监控」必须授权给 A-Kit.app —— 独立 app 那份授权不会自动生效。
@MainActor
final class AKeyStatsPlugin: NSObject, AKPluginDescriptor {

    private var state: AppState?
    private var panelHost: NSView?
    private var panelBuiltWidth: CGFloat = 0
    private var fullHost: NSView?

    var host: AKPluginHost?

    // MARK: 元信息

    var pluginId: String { "com.aibao.AKeyStats" }
    var displayName: String { "A-Key-Stats" }

    /// 版本从**自己的** .akitplugin 里读。
    ///
    /// 不能读 `Bundle.main` —— 插件进程里 `main` 是 A-Kit，会显示成 A-Kit 的版本号。
    var version: String { Self.pluginBundleVersion }

    var abiVersion: Int32 { AKPluginABIVersion }

    func statusItemImage() -> NSImage? { Self.appIcon() }

    func preferredPanelWidth() -> CGFloat { 346 }

    func statusText() -> String? { nil }

    // MARK: 界面

    func makePanelView(width: CGFloat) -> NSView {
        if let v = panelHost, abs(panelBuiltWidth - width) < 0.5 { return v }

        let root = PanelView(
            // 「打开」= 让宿主切到我的工具页（不是再开一个窗口）
            onOpen: { [weak self] in
                guard let self else { return }
                self.host?.presentFullPanel(self.pluginId)
            },
            // 插件形态不提供退出键，这里给个空实现兜底
            onQuit: {},
            width: width,
            allowsQuit: false
        )
        .environmentObject(ensureState())

        let v = NSHostingView(rootView: root)
        v.frame = NSRect(x: 0, y: 0, width: width, height: measure(v))
        panelHost = v
        panelBuiltWidth = width
        return v
    }

    func panelHeight(width: CGFloat) -> CGFloat {
        let v = makePanelView(width: width)
        v.layoutSubtreeIfNeeded()
        return measure(v)
    }

    func makePopoverView(width: CGFloat) -> NSView? { nil }

    func makeFullView() -> NSView {
        if let v = fullHost { return v }
        let root = RootView().environmentObject(ensureState())
        let v = NSHostingView(rootView: root)
        v.frame = NSRect(x: 0, y: 0, width: 1080, height: 720)
        fullHost = v
        return v
    }

    // MARK: 生命周期

    func activate() {
        let s = ensureState()
        s.onMenuBarTitleChange = { [weak self] text in
            self?.host?.setStatusText(text)
        }
        host?.setStatusText("今日 \(s.today.keyTotal) 键")
    }

    func deactivate() {
        state?.onMenuBarTitleChange = nil
        // 宿主进程还活着：采集必须停，否则 A-Kit 一开着就一直在数键
        state?.stop()
        state = nil
        panelHost = nil
        fullHost = nil
        panelBuiltWidth = 0
    }

    func handleEvent(_ name: String, payload: [String: String]?) {
        // 目前没有跨工具事件要处理
    }

    // MARK: 内部

    private func ensureState() -> AppState {
        if let s = state { return s }
        let s = AppState()
        state = s
        return s
    }

    private func measure(_ v: NSView) -> CGFloat {
        v.layoutSubtreeIfNeeded()
        return max(v.fittingSize.height, 120)
    }

    /// 本插件所在 dylib 的路径（用 dladdr 反查，不依赖 Bundle.main）
    private static var ownImagePath: String? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let c = info.dli_fname else { return nil }
        return String(cString: c)
    }

    /// 从 dylib 路径往上找它所属的 .akitplugin
    private static var pluginBundleURL: URL? {
        guard let p = ownImagePath else { return nil }
        var url = URL(fileURLWithPath: p)
        for _ in 0..<4 {
            if url.pathExtension == "akitplugin" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private static var pluginBundleVersion: String {
        if let u = pluginBundleURL,
           let d = try? Data(contentsOf: u.appendingPathComponent("Contents/Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
           let v = plist["CFBundleShortVersionString"] as? String {
            return v
        }
        return "0.0.0"
    }

    /// 图标优先用同一个 .app 里的 AppIcon，其次退回系统符号
    private static func appIcon() -> NSImage? {
        if let p = ownImagePath {
            var url = URL(fileURLWithPath: p)
            for _ in 0..<8 {
                if url.pathExtension == "app" {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.isTemplate = false
                    return icon
                }
                url = url.deletingLastPathComponent()
            }
        }
        let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "A-Key-Stats")
        img?.isTemplate = true
        return img
    }
}

// MARK: - 入口

@_cdecl("akit_plugin_main")
public func akit_plugin_main(_ hostPtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated {
        let host = Unmanaged<AnyObject>.fromOpaque(hostPtr).takeUnretainedValue() as? AKPluginHost
        let plugin = AKeyStatsPlugin()
        plugin.host = host
        return Unmanaged.passRetained(plugin).toOpaque()
    }
}
