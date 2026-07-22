import Foundation
import ServiceManagement

/// LoginItemControlling 封装“开机启动”能力，供 `AppViewModel` 注入，便于单元测试无需触碰真实系统状态。
public protocol LoginItemControlling {
    /// 当前系统记录的真实注册状态；不得以 UserDefaults 等本地偏好冒充（技术方案 §3.6）。
    var isEnabled: Bool { get }
    /// LoginItemControlling.setEnabled 尝试注册/取消注册开机启动项；失败时抛出错误，调用方需恢复开关显示。
    func setEnabled(_ enabled: Bool) throws
}

/// 基于 `SMAppService.mainApp` 的默认实现。
@available(macOS 13.0, *)
public struct SMLoginItemController: LoginItemControlling {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
