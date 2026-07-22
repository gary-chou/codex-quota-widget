import Testing
import Foundation
@testable import CodexQuotaCore

/// 覆盖测试用例.md §2.2「认证、网络与刷新状态」中协调器层的可单测部分（TC-02-01、TC-02-03 的聚合行为），
/// 以及「Token 读取失败属于部分成功」（TC-03-03 在协调器层的体现）。
struct RefreshCoordinatorTests {
    private let auth = CodexAuth(accessToken: fakeAccessToken, accountID: nil)
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func validUsageJSON() -> Data {
        """
        {"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":null},"secondary_window":null}}
        """.data(using: .utf8)!
    }

    @Test("正向：额度与 Token 均成功时产生完整快照，且 refreshedAt 来自注入的时钟")
    func successfulRefreshProducesFullSnapshot() async {
        let usage = FakeUsageFetching { _ in self.validUsageJSON() }
        let coordinator = QuotaRefreshCoordinator(
            authStore: FakeAuthProviding(result: .success(auth)),
            usageClient: usage,
            tokenReader: FakeRecentTokenReading(result: .value(4321)),
            clock: FakeClock(fixedDate: fixedDate)
        )

        let outcome = await coordinator.refresh()

        guard case .success(let snapshot) = outcome else {
            Issue.record("期望刷新成功，实际得到 \(outcome)")
            return
        }
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.recentTokens == .value(4321))
        #expect(snapshot.refreshedAt == fixedDate)
        #expect(usage.callCount == 1)
    }

    @Test("TC-03-03 部分成功：Token 读取失败不影响额度快照，仅标记为 unavailable")
    func tokenFailureDoesNotBlockSuccessfulQuotaSnapshot() async {
        let usage = FakeUsageFetching { _ in self.validUsageJSON() }
        let coordinator = QuotaRefreshCoordinator(
            authStore: FakeAuthProviding(result: .success(auth)),
            usageClient: usage,
            tokenReader: FakeRecentTokenReading(result: .unavailable),
            clock: FakeClock(fixedDate: fixedDate)
        )

        let outcome = await coordinator.refresh()

        guard case .success(let snapshot) = outcome else {
            Issue.record("期望刷新成功，实际得到 \(outcome)")
            return
        }
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.recentTokens == .unavailable)
    }

    @Test("TC-02-03 未登录/异常：凭据缺失直接返回 notSignedIn，且不发起用量请求")
    func missingCredentialsShortCircuitsWithoutNetworkCall() async {
        let usage = FakeUsageFetching { _ in self.validUsageJSON() }
        let coordinator = QuotaRefreshCoordinator(
            authStore: FakeAuthProviding(result: .failure(AuthError.notSignedIn)),
            usageClient: usage,
            tokenReader: FakeRecentTokenReading(result: .unavailable),
            clock: FakeClock(fixedDate: fixedDate)
        )

        let outcome = await coordinator.refresh()

        #expect(outcome == .failure(.notSignedIn))
        #expect(usage.callCount == 0)
    }

    @Test("TC-02-03 认证过期/异常：用量请求返回 401 时协调器透传 authenticationExpired")
    func authenticationExpiredPropagatesFromUsageClient() async {
        let usage = FakeUsageFetching { _ in throw UserFacingError.authenticationExpired }
        let coordinator = QuotaRefreshCoordinator(
            authStore: FakeAuthProviding(result: .success(auth)),
            usageClient: usage,
            tokenReader: FakeRecentTokenReading(result: .value(1)),
            clock: FakeClock(fixedDate: fixedDate)
        )

        let outcome = await coordinator.refresh()

        #expect(outcome == .failure(.authenticationExpired))
    }

    @Test("异常：额度响应无有效窗口时返回 invalidUsageResponse")
    func invalidUsageResponsePropagates() async {
        let usage = FakeUsageFetching { _ in
            "{\"rate_limit\":{\"primary_window\":null,\"secondary_window\":null}}".data(using: .utf8)!
        }
        let coordinator = QuotaRefreshCoordinator(
            authStore: FakeAuthProviding(result: .success(auth)),
            usageClient: usage,
            tokenReader: FakeRecentTokenReading(result: .unavailable),
            clock: FakeClock(fixedDate: fixedDate)
        )

        let outcome = await coordinator.refresh()

        #expect(outcome == .failure(.invalidUsageResponse))
    }
}

/// RefreshScheduler 的独立测试：验证启动即执行一次，并按周期重复，`stop()` 后不再触发。
struct RefreshSchedulerTests {
    @Test("正向：启动后立即执行一次，随后按周期重复执行")
    func startsImmediatelyAndRepeats() async throws {
        let counter = Counter()
        let scheduler = RefreshScheduler()

        await scheduler.start(interval: .milliseconds(20)) {
            await counter.increment()
        }

        // 等待足够时间让至少发生 2 次以上触发（首次立即触发 + 至少一次周期触发）。
        try await Task.sleep(for: .milliseconds(90))
        await scheduler.stop()

        let countAfterStop = await counter.value
        #expect(countAfterStop >= 2)

        // 停止后再等待一段时间，计数不应再增长。
        try await Task.sleep(for: .milliseconds(60))
        let countAfterWait = await counter.value
        #expect(countAfterWait == countAfterStop)
    }
}

/// 一个简单的 actor 计数器，避免测试中出现数据竞争。
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
