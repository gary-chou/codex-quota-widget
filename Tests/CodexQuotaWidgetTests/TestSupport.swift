import Foundation
import CodexQuotaCore
@testable import CodexQuotaWidget

// MARK: - 测试专用假数据与测试替身
//
// 隐私红线（对应 TC-03-04）：本文件出现的 token 一律使用明显不可用的假值。

let fakeWidgetAccessToken = "sk-test-FAKE-widget-0000000000000000notreal"

/// FakeAuthProviding 按预设结果返回凭据或抛出错误。
final class FakeAuthProviding: AuthProviding, @unchecked Sendable {
    var result: Result<CodexAuth, Error>

    init(result: Result<CodexAuth, Error>) {
        self.result = result
    }

    func load() throws -> CodexAuth {
        try result.get()
    }
}

/// FakeUsageFetching 记录调用次数，并按闭包生成结果或抛出错误。
final class FakeUsageFetching: UsageFetching, @unchecked Sendable {
    private(set) var callCount = 0
    var handler: (CodexAuth) async throws -> Data

    init(handler: @escaping (CodexAuth) async throws -> Data) {
        self.handler = handler
    }

    func fetch(auth: CodexAuth) async throws -> Data {
        callCount += 1
        return try await handler(auth)
    }
}

/// FakeRecentTokenReading 返回预设的 Token 结果。
struct FakeRecentTokenReading: RecentTokenReading {
    let result: RecentTokenResult

    func readLatest() async -> RecentTokenResult {
        result
    }
}

/// FakeClock 返回固定时间。
struct FakeClock: ClockProviding {
    let fixedDate: Date
    func now() -> Date { fixedDate }
}

/// FakePreferencesStorage 是内存版的偏好存储，避免测试污染真实 UserDefaults。
final class FakePreferencesStorage: PreferencesStorage, @unchecked Sendable {
    private var bools: [String: Bool] = [:]
    private var strings: [String: String] = [:]

    func bool(forKey key: String) -> Bool { bools[key] ?? false }
    func set(_ value: Bool, forKey key: String) { bools[key] = value }
    func string(forKey key: String) -> String? { strings[key] }
    func set(_ value: String?, forKey key: String) { strings[key] = value }
}

/// FakeLoginItemController 模拟开机启动的系统状态，成功/失败均可注入。
final class FakeLoginItemController: LoginItemControlling, @unchecked Sendable {
    var isEnabled: Bool
    var errorToThrow: Error?

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if let error = errorToThrow {
            throw error
        }
        isEnabled = enabled
    }
}

struct FakeLoginItemError: Error {}

/// 构造一段可解析出单个 5h 窗口的合法用量 JSON，便于测试快速产生成功快照。
func validUsageJSON(usedPercent: Double = 25) -> Data {
    """
    {"rate_limit":{"primary_window":{"used_percent":\(usedPercent),"limit_window_seconds":18000,"reset_at":null},"secondary_window":null}}
    """.data(using: .utf8)!
}

/// 便捷构造 `QuotaWindow`，供纯 UI 状态测试（如 StatusItemController.title）直接使用。
func makeQuotaWindow(seconds: Int, usedPercent: Double) throws -> QuotaWindow {
    try QuotaWindow(raw: RawRateLimitWindow(usedPercent: usedPercent, limitWindowSeconds: seconds, resetAt: nil))
}

/// 便捷构造一个可注入的 `AppViewModel`，供 ViewModel 测试复用。
@MainActor
func makeViewModel(
    usage: UsageFetching,
    auth: AuthProviding = FakeAuthProviding(result: .success(CodexAuth(accessToken: fakeWidgetAccessToken))),
    tokenReader: RecentTokenReading = FakeRecentTokenReading(result: .unavailable),
    clock: ClockProviding = FakeClock(fixedDate: Date(timeIntervalSince1970: 1_700_000_000)),
    preferences: PreferencesStore = PreferencesStore(storage: FakePreferencesStorage()),
    loginItemController: LoginItemControlling = FakeLoginItemController()
) -> AppViewModel {
    let coordinator = QuotaRefreshCoordinator(
        authStore: auth,
        usageClient: usage,
        tokenReader: tokenReader,
        clock: clock
    )
    return AppViewModel(
        coordinator: coordinator,
        preferences: preferences,
        loginItemController: loginItemController
    )
}
