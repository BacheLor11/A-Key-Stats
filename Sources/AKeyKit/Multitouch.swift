import Foundation
import IOKit

// MARK: - MultitouchSupport 私有框架封装
//
// 这个框架是系统自带的私有组件，Apple 随时可能改。所有符号都用 dlopen 动态取，
// 取不到就当"不支持"，不要让整个 app 崩掉。

public struct TouchContact {
    public var id: Int32
    public var x: Double        // 归一化 0..1
    public var y: Double        // 归一化 0..1（原点在左下，交给上层翻）
    public var size: Double     // 接触面积，≈ 力度
}

public struct MTDeviceInfo: Equatable {
    public enum Kind: String {
        case trackpad
        case mouse
        case builtInTrackpad
        case unknown
    }

    public var locationID: Int
    public var name: String
    public var kind: Kind

    public var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .builtInTrackpad: return "内建触控板"
        case .trackpad: return "触控板"
        case .mouse: return "鼠标"
        case .unknown: return "触控设备"
        }
    }
}

public final class PadTap {
    public private(set) var devices: [MTDeviceInfo] = []
    public private(set) var isRunning = false

    /// 每帧回调：设备 + 该帧所有接触点
    public var onFrame: ((MTDeviceInfo, [TouchContact]) -> Void)?

    private var handle: UnsafeMutableRawPointer?
    private var rawDevices: [UnsafeMutableRawPointer] = []

    private typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CallbackFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, CallbackFn) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias GetIntFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32

    private var stopFn: StopFn?

    public static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    public init() {}

    // MARK: 指纹结构体字段偏移（64 位下 sizeof = 96）
    private enum Off {
        static let identifier = 16
        static let state = 20
        static let x = 32
        static let y = 36
        static let size = 48
    }

    // MARK: 启动

    public func start() -> Bool {
        guard !isRunning else { return true }
        guard let h = dlopen(Self.frameworkPath, RTLD_NOW) else { return false }
        handle = h

        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
        }

        guard let createList = symbol("MTDeviceCreateList", CreateListFn.self),
              let register = symbol("MTRegisterContactFrameCallback", RegisterFn.self),
              let startDevice = symbol("MTDeviceStart", StartFn.self) else {
            return false
        }
        stopFn = symbol("MTDeviceStop", StopFn.self)
        let getDeviceID = symbol("MTDeviceGetDeviceID", GetIntFn.self)

        guard let listRaw = createList() else { return false }
        let list = Unmanaged<CFArray>.fromOpaque(listRaw).takeUnretainedValue()

        let metal = Self.multitouchRegistry()

        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = unsafeBitCast(raw, to: UnsafeMutableRawPointer.self)
            var locationID: Int32 = 0
            _ = getDeviceID?(device, &locationID)
            let info = metal[Int(locationID)] ?? MTDeviceInfo(locationID: Int(locationID),
                                                             name: "",
                                                             kind: .unknown)
            devices.append(info)
            rawDevices.append(device)
            Self.shared = self
            register(device, padTapCallback)
            startDevice(device, 0)
        }

        isRunning = !rawDevices.isEmpty
        return isRunning
    }

    public func stop() {
        for device in rawDevices { stopFn?(device) }
        rawDevices.removeAll()
        isRunning = false
    }

    // MARK: 设备识别（LocationID 对 ioreg 的 AppleMultitouchDevice）

    /// MTDeviceGetDeviceID 拿到的就是 ioreg 里的 LocationID，用它对上设备名与"是否内建"。
    /// 这一步很关键：Magic Mouse 表面同样会上报接触点，不区分就会把鼠标算进触控板。
    static func multitouchRegistry() -> [Int: MTDeviceInfo] {
        var result: [Int: MTDeviceInfo] = [:]
        let matching = IOServiceMatching("AppleMultitouchDevice")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> AnyObject? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            guard let locationNumber = property("LocationID") as? NSNumber else { continue }
            let locationID = locationNumber.intValue
            let product = (property("Product") as? String) ?? ""
            let builtIn = (property("MT Built-In") as? NSNumber)?.boolValue ?? false

            let kind: MTDeviceInfo.Kind
            let lower = product.lowercased()
            if builtIn {
                kind = .builtInTrackpad
            } else if lower.contains("mouse") {
                kind = .mouse
            } else if lower.contains("trackpad") {
                kind = .trackpad
            } else {
                kind = product.isEmpty ? .unknown : .trackpad
            }
            result[locationID] = MTDeviceInfo(locationID: locationID, name: product, kind: kind)
        }
        return result
    }

    /// 调试用：列出所有多点触控设备的识别结果
    public static func describeDevices() -> [String] {
        multitouchRegistry().values
            .sorted { $0.locationID < $1.locationID }
            .map { "\($0.kind.rawValue) · \($0.displayName) · LocationID \($0.locationID)" }
    }

    // MARK: 回调

    fileprivate func handleFrame(deviceIndex raw: UnsafeMutableRawPointer?,
                                fingers base: UnsafeMutableRawPointer?,
                                count: Int32) {
        guard let base, count > 0 else { return }
        var contacts: [TouchContact] = []
        contacts.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let pointer = base + i * 96
            let id = pointer.load(fromByteOffset: Off.identifier, as: Int32.self)
            let x = pointer.load(fromByteOffset: Off.x, as: Float.self)
            let y = pointer.load(fromByteOffset: Off.y, as: Float.self)
            let size = pointer.load(fromByteOffset: Off.size, as: Float.self)
            guard x >= 0, x <= 1, y >= 0, y <= 1, size > 0.01 else { continue }
            contacts.append(TouchContact(id: id, x: Double(x), y: Double(y), size: Double(size)))
        }
        guard !contacts.isEmpty else { return }

        // 用设备地址找回对应的 info（MT 回调不告诉我们是哪台设备）
        guard let raw, let index = rawDevices.firstIndex(of: raw), index < devices.count else { return }
        onFrame?(devices[index], contacts)
    }

    fileprivate static var shared: PadTap?
}

private let padTapCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void = {
    device, fingers, count, _, _ in
    PadTap.shared?.handleFrame(deviceIndex: device, fingers: fingers, count: count)
}
