// swift-tools-version:5.9
import PackageDescription

/// CodexQuotaWidget 工程定义：一个纯本地 macOS 菜单栏应用，展示 Codex 用量额度。
///
/// 拆分为两个模块：
/// - `CodexQuotaCore`：不依赖 UI 的领域逻辑（解析、认证、网络、Token 统计、刷新状态机），
///   所有 IO（文件/网络/时钟/开机启动）通过协议注入，便于单元测试。
/// - `CodexQuotaWidget`：AppKit + SwiftUI 组成的菜单栏可执行程序，依赖 `CodexQuotaCore`。
let package = Package(
    name: "CodexQuotaWidget",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexQuotaCore", targets: ["CodexQuotaCore"]),
        .executable(name: "CodexQuotaWidget", targets: ["CodexQuotaWidget"])
    ],
    // 本机只安装 Swift Command Line Tools（无完整 Xcode），系统不提供 XCTest.framework
    // 也不提供预编译的 Testing.swiftmodule。显式声明 swift-testing 源码依赖，
    // 使测试框架随目标一起从源码编译，从而摆脱对 Xcode 的依赖。
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "CodexQuotaCore",
            path: "Sources/CodexQuotaCore"
        ),
        .executableTarget(
            name: "CodexQuotaWidget",
            dependencies: ["CodexQuotaCore"],
            path: "Sources/CodexQuotaWidget"
        ),
        .testTarget(
            name: "CodexQuotaCoreTests",
            dependencies: [
                "CodexQuotaCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/CodexQuotaCoreTests"
        ),
        .testTarget(
            name: "CodexQuotaWidgetTests",
            dependencies: [
                "CodexQuotaWidget",
                "CodexQuotaCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/CodexQuotaWidgetTests"
        )
    ]
)
