// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "A-Key-Stats",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AKeyStats", targets: ["AKeyApp"]),
        .library(name: "AKeyKit", targets: ["AKeyKit"]),
        // 插件形态：A-Kit 用 dlopen 加载这个 dylib，界面直接嵌进 A-Kit
        .library(name: "AKeyPlugin", type: .dynamic, targets: ["AKeyPlugin"]),
    ],
    targets: [
        // 采集引擎：键鼠计数 / 多点触控 / 存储。没有一行 UI，方便命令行自检
        .target(name: "AKeyKit", path: "Sources/AKeyKit"),
        // 博客皮肤 + 六个页面
        .target(name: "AKeyUI", dependencies: ["AKeyKit"], path: "Sources/AKeyUI"),
        // 可执行入口：主窗口 / 菜单栏 / A-Kit 接入
        .executableTarget(
            name: "AKeyApp",
            dependencies: ["AKeyKit", "AKeyUI", "AKitStatusKit"],
            path: "Sources/AKeyApp"
        ),
        // A-Kit 单文件 SDK（MIT，直接从 A-Kit 复制过来）
        .target(name: "AKitStatusKit", path: "Sources/Vendor"),
        // A-Kit 插件契约（同样是 vendored 的单文件，由 A-Kit 的 Scripts/sync_sdk.sh 同步）
        .target(name: "AKitPluginKit", path: "Sources/AKitPluginKit"),
        // 插件壳：把 AKeyUI 的面板 / 整页包成 A-Kit 能嵌的 NSView。
        // 只依赖契约和 UI，不碰 AKeyApp（那里面有 NSApp / 窗口 / 菜单栏）。
        .target(
            name: "AKeyPlugin",
            dependencies: ["AKeyKit", "AKeyUI", "AKitPluginKit"],
            path: "Sources/AKeyPlugin"
        ),
    ],
    swiftLanguageModes: [.v5]
)
