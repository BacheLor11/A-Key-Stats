import Foundation
import IOKit.hid

/// 键鼠原始输入。走 IOHIDManager 而不是 CGEventTap：
/// 只有它能告诉我们"这个键是哪块键盘按的"，而且拿到的是物理 keyCode。
public final class InputTap {
    public enum Access {
        case granted
        case denied
        case unknown
    }

    public struct DeviceRef {
        public var name: String
        public var usagePage: Int
        public var usage: Int
    }

    /// 虚拟键码（kVK_*）+ 设备名。注意不是 HID usage，进来时就换算过了。
    public var onKeyDown: ((UInt16, String) -> Void)?
    public var onKeyUp: ((UInt16, String) -> Void)?
    /// 0 = 左键，1 = 右键，2 = 中键
    public var onMouseButton: ((Int, String) -> Void)?
    public var onMouseButtonUp: ((Int, String) -> Void)?
    /// 原始 usage + 换算后的虚拟键码（nil 表示映射表里没有），调试/自校准用
    public var onRawKey: ((UInt16, UInt16?, String) -> Void)?
    /// 同一颗键在极短时间内被重复上报（已被去重），调试用
    public var onDuplicateKey: ((UInt16, String) -> Void)?

    public private(set) var keyboardNames: [String] = []
    public private(set) var mouseNames: [String] = []
    public private(set) var isOpen = false
    public private(set) var receivedEvents = 0
    /// 无法映射到虚拟键码的 usage（诊断用，正常应该一直是 0）
    public private(set) var unmappedUsages: [UInt16: Int] = [:]
    /// 被去重挡掉的重复事件数（同一颗键被多路接口重复上报）
    public private(set) var dedupedEvents = 0

    private var manager: IOHIDManager?
    private var pressed: [UInt64: Set<Int>] = [:]   // 物理设备身份 | page -> 按下的 usage（去自动重复）
    private var deviceKeys: [UnsafeMutableRawPointer: UInt64] = [:]
    /// usage -> 上次计数的单调时钟（纳秒）。同一个键 20ms 内只算一次：
    /// 一块键盘可能同时以 Keyboard 和 Keypad 两个接口枚举出来，各自上报同一颗键。
    private var lastCountedAt: [Int: UInt64] = [:]
    private let duplicateWindow: UInt64 = 35_000_000
    /// 真正计过数的 usage，抬起时只对这些发 onKeyUp（被去重挡掉的那一份不再冒一次）
    private var countedUsages: Set<Int> = []

    public init() {}

    // MARK: 权限

    public static func access() -> Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    public static func requestAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: 启动

    @discardableResult
    public func start() -> Bool {
        guard manager == nil else { return true }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x06], // 键盘
            [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x07], // 小键盘
            [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x02], // 鼠标/触控板指针
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, hidValueCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        isOpen = (result == kIOReturnSuccess)
        refreshDevices()
        return isOpen
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        isOpen = false
    }

    /// 关掉重开。
    ///
    /// 授权是在 app 跑起来之后才给的时候，光 refreshDevices() 是不够的 ——
    /// IOHIDManager 在 open 那一刻就把「能不能读键盘」定下来了，设备列表会更新，
    /// 事件回调却不会开始送。所以用户点「重新检测」时整条链路重建一次，
    /// 不用退出 app 再开。
    @discardableResult
    public func restart() -> Bool {
        stop()
        deviceKeys.removeAll()
        pressed.removeAll()
        lastCountedAt.removeAll()
        countedUsages.removeAll()
        return start()
    }

    /// 重新枚举当前已授权的键鼠设备名
    public func refreshDevices() {
        guard let manager, let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        var keyboards: Set<String> = []
        var mice: Set<String> = []
        for device in set {
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "HID 设备"
            guard let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int,
                  let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int else { continue }
            if page == 0x01, usage == 0x06 || usage == 0x07 {
                keyboards.insert(name)
            } else if page == 0x01, usage == 0x02 {
                mice.insert(name)
            }
        }
        keyboardNames = keyboards.sorted()
        mouseNames = mice.sorted()
    }

    // MARK: 回调

    /// 同一块物理键盘常被 IOHIDManager 匹配出多个设备对象（Keyboard / Keypad / 厂商接口），
    /// 用厂商+产品+位置拼一个稳定身份，让它们共用同一份"已按下"表。
    /// 只用指针做 key 的话，两个对象各算一套，按一次键会记两次 —— 这是之前「一按两下」的根源。
    private func stableKey(_ device: IOHIDDevice) -> UInt64 {
        if let cached = deviceKeys[Unmanaged.passUnretained(device).toOpaque()] { return cached }
        func number(_ key: CFString) -> UInt64 {
            (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.uint64Value ?? 0
        }
        let vendor = number(kIOHIDVendorIDKey as CFString)
        let product = number(kIOHIDProductIDKey as CFString)
        let location = number(kIOHIDLocationIDKey as CFString)
        var key = (vendor & 0xFFFF) << 48 | (product & 0xFFFF) << 32 | (location & 0xFFFFFFFF)
        if key == 0 {
            // 没有这些属性就退回产品名 + 接口页
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
            key = UInt64(truncatingIfNeeded: name.hashValue) | 1
        }
        deviceKeys[Unmanaged.passUnretained(device).toOpaque()] = key
        return key
    }

    fileprivate func handle(value: IOHIDValue, device: IOHIDDevice) {
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let intValue = IOHIDValueGetIntegerValue(value)
        let deviceName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "HID"

        receivedEvents += 1

        // 键盘：usagePage 0x07。按住会反复来 value=1，用 pressed 集合挡掉自动重复
        if usagePage == 0x07 {
            guard usage != 0 else { return }        // usage 0 = "没有键"，键盘松开时常报
            let key = stableKey(device) | 7
            var set = pressed[key] ?? []
            if intValue == 1 {
                guard !set.contains(usage) else { return }
                set.insert(usage)
                pressed[key] = set

                // 跨设备对象的兜底去重：同一颗键 35ms 内只算一次
                let now = DispatchTime.now().uptimeNanoseconds
                if let last = lastCountedAt[usage], now &- last < duplicateWindow {
                    dedupedEvents += 1
                    // 换算成键码再上报，让检测页能显示是哪颗键重复了
                    onDuplicateKey?(HIDKeymap.virtualKey(for: UInt16(usage)) ?? UInt16(usage), deviceName)
                    return
                }
                lastCountedAt[usage] = now
                countedUsages.insert(usage)

                // ★ 这里必须换算：HID usage 和 macOS 虚拟键码是两套编号
                let vk = HIDKeymap.virtualKey(for: UInt16(usage))
                if vk == nil { unmappedUsages[UInt16(usage), default: 0] += 1 }
                onRawKey?(UInt16(usage), vk, deviceName)
                if let vk { onKeyDown?(vk, deviceName) }
            } else if intValue == 0 {
                set.remove(usage)
                pressed[key] = set
                // 故意不清 lastCountedAt：让「按下-抬起-又按下」这种 35ms 内的抖动也被挡住，
                // 它本来就该算一次；真的想连按两次，人手做不到这么快。
                if countedUsages.remove(usage) != nil,
                   let vk = HIDKeymap.virtualKey(for: UInt16(usage)) {
                    onKeyUp?(vk, deviceName)
                }
            }
            return
        }

        // 按钮：usagePage 0x09，usage 1/2/3 = 左/右/中
        if usagePage == 0x09, (1...3).contains(usage) {
            let key = stableKey(device) | 9
            var set = pressed[key] ?? []
            let index = usage - 1
            if intValue == 1 {
                if !set.contains(usage) {
                    set.insert(usage)
                    pressed[key] = set
                    onMouseButton?(index, deviceName)
                }
            } else if intValue == 0 {
                set.remove(usage)
                pressed[key] = set
                onMouseButtonUp?(index, deviceName)
            }
        }
    }
}

private let hidValueCallback: IOHIDValueCallback = { context, _, sender, value in
    guard let context, let sender else { return }
    let tap = Unmanaged<InputTap>.fromOpaque(context).takeUnretainedValue()
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    tap.handle(value: value, device: device)
}
