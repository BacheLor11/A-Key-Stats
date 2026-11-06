import Foundation
import AppKit

/// 插件 ABI 版本。
///
/// 宿主加载插件后**必须先校验这个值**，不匹配直接拒绝加载。
/// 新旧 ABI 混跑会把宿主带崩，宁可让插件显示「需要更新」。
///
/// 版本变更规则：
/// - 新增可选方法：不升版本（插件不实现就调不到，宿主自行兜底）
/// - 改已有方法签名 / 语义：必须升版本
public let AKPluginABIVersion: Int32 = 1

/// 插件导出入口的 C 符号名。插件必须导出这个符号，签名固定。
///
/// ```swift
/// @_cdecl("akit_plugin_main")
/// public func akit_plugin_main(_ host: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
/// ```
public let AKPluginEntrySymbol = "akit_plugin_main"

// MARK: - 插件描述符

/// 工具的插件形态。
///
/// 刻意用 `@objc` 协议而不是纯 Swift：纯 Swift 的类/协议跨 dylib 传递会绑死编译器
/// metadata 布局，宿主和插件必须用同一版本工具链才能对上。走 Objective-C runtime
/// 就只按类名/协议名匹配，两边各自编译也能工作。
///
/// 代价：方法签名必须 ObjC 兼容（不能有 Swift struct、泛型、元组）。
@objc(AKPluginDescriptor)
public protocol AKPluginDescriptor: NSObjectProtocol {
    /// 唯一标识，建议用工具的 bundle id，例如 `com.aibao.ASweep`
    var pluginId: String { get }
    /// 显示名，例如 `A-Sweep`
    var displayName: String { get }
    /// 工具自身版本，例如 `0.5.0`
    var version: String { get }
    /// 必须等于 `AKPluginABIVersion`
    var abiVersion: Int32 { get }

    /// 菜单栏图标（模板图，18×18）。返回 nil 时宿主用方块占位。
    func statusItemImage() -> NSImage?

    /// 面板里的菜单界面（窄，约 300-340pt 宽）。
    /// 这就是工具原本挂在菜单栏上的那份界面，不是重绘的。
    func makePanelView(width: CGFloat) -> NSView

    /// 上面那个界面在给定宽度下要多高。
    ///
    /// 宿主不猜高度——面板是"固定宽 + 动态高"的卡片流，高度必须由插件报。
    /// 内容变了就调 `host.requestLayoutRefresh()`，宿主会重新问一次。
    func panelHeight(width: CGFloat) -> CGFloat

    /// 点菜单栏图标时弹出的小界面（可选）。
    /// 返回 nil 时宿主复用 `makePanelView`。
    func makePopoverView(width: CGFloat) -> NSView?

    /// 这个工具的界面最少要多宽（可选）。
    ///
    /// 宿主的面板是「宽度取所有工具的最大需求、高度跟着内容走」，
    /// 不实现就按宿主的默认宽度（336pt）算。
    /// 旧插件不实现也没关系 —— 所以标成 optional，不升 ABI 版本。
    @objc optional func preferredPanelWidth() -> CGFloat

    /// 控制台里的完整界面（大，整页）。
    /// 插件**不允许**自己开主窗口——那会让 ⌘Q 退掉整个 A-Kit。
    func makeFullView() -> NSView

    /// 折叠态显示的一行状态文字
    func statusText() -> String?

    /// 被宿主加载
    func activate()
    /// 被宿主卸载 / 宿主退出
    func deactivate()

    /// 收到别的工具发来的事件（可选实现）。
    ///
    /// 标成 `@objc optional` 是为了不升 ABI：早期插件没实现也不影响加载，
    /// 宿主调用时会做存在性判断。
    @objc optional func handleEvent(_ name: String, payload: [String: String]?)
}

// MARK: - 宿主回调

/// 插件反向调用宿主的能力（`@objc` 的原因同 `AKPluginDescriptor`）。
@objc(AKPluginHost)
public protocol AKPluginHost: NSObjectProtocol {
    /// 我的界面高度变了，请重新贴合
    func requestLayoutRefresh()

    /// 更新折叠态那一行状态
    func setStatusText(_ text: String?)

    /// 换菜单栏图标（`hubbar` 模式下宿主会立刻换）
    func setStatusItemImage(_ image: NSImage?)

    /// 请宿主打开我的完整界面
    func presentFullPanel(_ pluginId: String)

    /// 请宿主把主窗口拉到前台
    func openWindow()

    /// 发事件给其他工具（事件总线）
    func emit(_ event: String, payload: [String: String]?)

    /// 写日志（归到宿主的日志里，带插件前缀）
    func log(_ message: String)
}

// MARK: - 插件清单

/// 一个已装插件的静态信息（来自 Info.plist + 文件系统，不需要加载 dylib）
public struct AKPluginRecord: Codable, Identifiable, Hashable {
    public var id: String              // pluginId
    public var displayName: String
    public var version: String
    public var bundlePath: String      // .akitplugin 的绝对路径（可能是软链）
    public var executablePath: String
    public var abiVersion: Int32
    public var appPath: String?        // 宿主 app 的路径（both 模式下有）
    public var signedTeamId: String?

    public init(id: String, displayName: String, version: String,
                bundlePath: String, executablePath: String, abiVersion: Int32,
                appPath: String? = nil, signedTeamId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.abiVersion = abiVersion
        self.appPath = appPath
        self.signedTeamId = signedTeamId
    }
}
