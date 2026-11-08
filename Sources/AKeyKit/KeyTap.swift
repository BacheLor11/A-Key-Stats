import Foundation
import CoreGraphics

/// 事件层兜底：当系统里看不到键盘 HID 设备时，改听窗口服务器层的按键。
///
/// IOHIDManager 只认得「本机的 HID 键盘设备」。两种情况下它是瞎的：
///   1. 输入监控没真正生效 —— 系统会把键盘设备对非授权进程藏起来（鼠标、触控板不受影响）；
///   2. 按键不是本机键盘发出的 —— 通用控制、远程桌面、部分 KVM 都是把按键注入事件层，
///      压根没有对应的 HID 设备。
/// 这两种情况 Trackpad 都还能记（走 MultitouchSupport，不吃这套权限），于是就成了
/// 「触控板有数、键盘没数」。事件层监听能补上，代价是拿不到设备名。
public final class KeyTap {
    /// 兜底记下来的按键归到这个设备名下，界面上能看出来源
    public static let deviceName = "系统事件"

    public var onKeyDown: ((UInt16) -> Void)?
    public var onKeyUp: ((UInt16) -> Void)?

    public private(set) var isRunning = false
    public private(set) var events = 0

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init() {}

    // MARK: 权限

    /// 监听键盘事件需要的权限（和输入监控是同一个 TCC 服务）
    public static func canListen() -> Bool {
        CGPreflightListenEventAccess()
    }

    public static func requestListen() {
        _ = CGRequestListenEventAccess()
    }

    // MARK: 生命周期

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap,
                                           place: .headInsertEventTap,
                                           options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask),
                                           callback: keyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.source = source
        isRunning = true
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
    }

    // MARK: 回调

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        // 系统嫌我们处理慢了会把 tap 停掉，必须自己开回来，否则之后一条都收不到
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // 按住不放产生的自动重复只算一次
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }

        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        events += 1
        switch type {
        case .keyDown: onKeyDown?(code)
        case .keyUp: onKeyUp?(code)
        default: break
        }
    }
}

private let keyTapCallback: CGEventTapCallBack = { _, type, event, context in
    if let context {
        let tap = Unmanaged<KeyTap>.fromOpaque(context).takeUnretainedValue()
        tap.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
