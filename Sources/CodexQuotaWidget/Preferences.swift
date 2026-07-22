import Foundation

/// PreferencesStorage 隔离底层键值存储（生产环境为 `UserDefaults`），供测试注入内存实现。
public protocol PreferencesStorage {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// 基于 `UserDefaults` 的默认存储实现。
///
/// 不直接让 `UserDefaults` 遵循 `PreferencesStorage`：`UserDefaults.set(_:forKey:)` 的参数类型是
/// `Any?`，与协议要求的 `String?` 精确签名不匹配，用显式包装类型转发调用更清晰可靠。
public struct UserDefaultsPreferencesStorage: PreferencesStorage {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// PreferencesStore 只保存非敏感的用户偏好：悬浮窗开关与位置。
///
/// 明确不持久化任何认证凭据（结构化需求 §3.6、技术方案 §6）。
public final class PreferencesStore {
    private enum Keys {
        static let floatingVisible = "com.codexquotawidget.preferences.floatingVisible"
        static let floatingFrame = "com.codexquotawidget.preferences.floatingFrame"
    }

    private let storage: PreferencesStorage

    public init(storage: PreferencesStorage = UserDefaultsPreferencesStorage()) {
        self.storage = storage
    }

    /// 悬浮窗是否显示；默认关闭（结构化需求 §3.3）。
    public var floatingVisible: Bool {
        get { storage.bool(forKey: Keys.floatingVisible) }
        set { storage.set(newValue, forKey: Keys.floatingVisible) }
    }

    /// 悬浮窗上次的位置与大小；未设置过时返回 nil，由调用方选择默认位置。
    public var floatingFrame: CGRect? {
        get {
            guard let raw = storage.string(forKey: Keys.floatingFrame) else { return nil }
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { return nil }
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        set {
            guard let frame = newValue else {
                storage.set(nil, forKey: Keys.floatingFrame)
                return
            }
            let raw = "\(frame.origin.x),\(frame.origin.y),\(frame.size.width),\(frame.size.height)"
            storage.set(raw, forKey: Keys.floatingFrame)
        }
    }
}
