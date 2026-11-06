import Foundation

// MARK: - 菜单模型（工具与 Hub 之间的线协议）

public struct AKMenuItem: Codable, Identifiable {
    public enum Kind: String, Codable {
        case item       // 普通可点击项
        case toggle     // 勾选项
        case header     // 分组标题（不可点）
        case separator  // 分隔线
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var enabled: Bool
    public var checked: Bool?
    public var shortcut: String?
    public var children: [AKMenuItem]?

    public init(id: String, title: String, kind: Kind = .item, enabled: Bool = true,
                checked: Bool? = nil, shortcut: String? = nil, children: [AKMenuItem]? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.enabled = enabled
        self.checked = checked
        self.shortcut = shortcut
        self.children = children
    }

    public static func separator(_ id: String = UUID().uuidString) -> AKMenuItem {
        AKMenuItem(id: id, title: "", kind: .separator)
    }

    public static func header(_ title: String, id: String = UUID().uuidString) -> AKMenuItem {
        AKMenuItem(id: id, title: title, kind: .header, enabled: false)
    }
}

public struct AKToolInfo: Codable {
    public var bundleId: String
    public var name: String
    public var version: String
    public var status: String?
    public var menu: [AKMenuItem]
    /// 该工具愿意接收的事件名（见事件总线）
    public var subscribes: [String]?

    public init(bundleId: String, name: String, version: String,
                status: String? = nil, menu: [AKMenuItem] = [], subscribes: [String]? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.version = version
        self.status = status
        self.menu = menu
        self.subscribes = subscribes
    }
}

// MARK: - 连接

final class AKHubSocket {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "app.askb.akit.client")

    var onLine: ((String) -> Void)?
    var onClose: (() -> Void)?

    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("A-Kit/hub.sock").path
    }

    var isOpen: Bool { fd >= 0 }

    func connect(path: String = AKHubSocket.defaultPath) -> Bool {
        close()
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cs in
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    _ = strlcpy(dst, cs, maxLen)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bindPtr in
                Darwin.connect(sock, bindPtr, size)
            }
        }
        guard r == 0 else {
            Darwin.close(sock)
            return false
        }
        fd = sock

        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { Darwin.close(f) }
            self?.fd = -1
        }
        source = src
        src.resume()
        return true
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 {
            close()
            onClose?()
            return
        }
        buffer.append(contentsOf: buf[0..<n])
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                onLine?(line)
            }
        }
    }

    func send(_ object: [String: Any]) {
        guard fd >= 0,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let n = Darwin.send(fd, base.advanced(by: sent), payload.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    func close() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        buffer.removeAll()
    }
}

// MARK: - 给工具 app 用的客户端

/// 接入 A-Kit 的客户端。
///
/// 设计原则：**可有可无**。
/// - 连不上 Hub（没装 / 没运行 / 崩溃）时，`isConnected` 为 false，
///   工具应当照常显示自己的菜单栏图标，行为与接入前完全一致。
/// - 连上后可以隐藏自己的图标，把菜单交给 Hub 渲染。
///
/// ```swift
/// AKHubClient.shared.onConnectionChange = { connected in
///     statusItem.isVisible = !connected
/// }
/// AKHubClient.shared.start(info: AKToolInfo(bundleId: "com.example.MyTool",
///                                           name: "MyTool",
///                                           version: "1.2.0",
///                                           menu: myMenu))
/// ```
public final class AKHubClient {
    public static let shared = AKHubClient()

    /// Hub 里点了某个菜单项
    public var onInvoke: ((_ itemId: String) -> Void)?
    /// Hub 发来的事件（事件总线）
    public var onEvent: ((_ name: String, _ payload: [String: String]) -> Void)?
    /// 连接状态变化 —— 用它来切换自己图标的显示
    public var onConnectionChange: ((_ connected: Bool) -> Void)?

    public private(set) var isConnected = false {
        didSet { if isConnected != oldValue { DispatchQueue.main.async { self.onConnectionChange?(self.isConnected) } } }
    }

    private let socket = AKHubSocket()
    private var current: AKToolInfo?
    private var reconnectTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.askb.akit.client.manager")
    private var wantsConnection = false

    private init() {
        socket.onLine = { [weak self] line in self?.handle(line) }
        socket.onClose = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.listenForDown()
        }
    }

    public func start(info: AKToolInfo) {
        current = info
        wantsConnection = true
        attachIfPossible()
    }

    /// 菜单或状态变了，推一次给 Hub。
    ///
    /// 注意：这是「整包重发」，Hub 侧会重建这个工具的条目。只有菜单项结构
    /// 变了才用它；单纯刷新状态文字请用 `pushStatus(_:)`。
    public func update(menu: [AKMenuItem]? = nil, status: String? = nil) {
        guard var info = current else { return }
        if let menu { info.menu = menu }
        if let status { info.status = status }
        current = info
        guard isConnected else { return }
        sendRegister(info)
    }

    /// 只推状态文字（面板卡片 / 菜单栏副标题那一行），不重发菜单。
    ///
    /// 高频刷新状态（CPU、内存、进度这类每秒都在变的数字）请一律走这里：
    /// 走 `update(status:)` 会整包重发，Hub 每秒重建一次条目，日志也会被刷满。
    /// 文本没变化时直接返回，不产生任何网络写入。
    public func pushStatus(_ text: String) {
        guard var info = current, info.status != text else { return }
        info.status = text
        current = info
        guard isConnected else { return }
        socket.send(["jsonrpc": "2.0", "id": UUID().uuidString,
                     "method": "status", "params": ["status": text]])
    }

    /// 发一个事件给 Hub（会转发给订阅了该事件的其他工具）
    public func emit(_ name: String, payload: [String: String] = [:]) {
        guard isConnected else { return }
        socket.send(["jsonrpc": "2.0", "id": UUID().uuidString, "method": "event",
                     "params": ["name": name, "payload": payload]])
    }

    /// Hub 是否在跑（只看 socket 文件在不在，不建立连接）
    public static var isHubRunning: Bool {
        FileManager.default.fileExists(atPath: AKHubSocket.defaultPath)
    }

    public func stop() {
        wantsConnection = false
        reconnectTimer?.cancel()
        reconnectTimer = nil
        socket.close()
        isConnected = false
    }

    // MARK: 内部

    private func attachIfPossible() {
        guard wantsConnection else { return }
        guard let info = current else { return }
        if socket.connect() {
            isConnected = true
            sendRegister(info)
        } else {
            isConnected = false
            listenForDown()
        }
    }

    /// 5 秒一次的轻量重试。连不上什么都不做，绝不影响宿主 app。
    private func listenForDown() {
        guard wantsConnection else { return }
        reconnectTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, self.wantsConnection, !self.socket.isOpen else { return }
            self.attachIfPossible()
        }
        t.resume()
        reconnectTimer = t
    }

    private func sendRegister(_ info: AKToolInfo) {
        guard let data = try? JSONEncoder().encode(info),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        socket.send(["jsonrpc": "2.0", "id": UUID().uuidString, "method": "register", "params": obj])
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else { return }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "invoke":
            if let itemId = params["itemId"] as? String {
                DispatchQueue.main.async { self.onInvoke?(itemId) }
            }
        case "event":
            let name = params["name"] as? String ?? ""
            let payload = (params["payload"] as? [String: Any])?.reduce(into: [String: String]()) { acc, kv in
                acc[kv.key] = "\(kv.value)"
            } ?? [:]
            DispatchQueue.main.async { self.onEvent?(name, payload) }
        case "requestMenu":
            if let info = current { sendRegister(info) }
        case "ping":
            socket.send(["jsonrpc": "2.0", "id": UUID().uuidString, "method": "pong", "params": [:]])
        default:
            break
        }
    }
}
