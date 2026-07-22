import Testing
import Foundation
import CodexQuotaCore
@testable import CodexQuotaWidget

/// 覆盖测试用例.md 中 TC-02-04、TC-02-05、TC-02-06（AppViewModel 的失败保留/恢复/防重）
/// 以及 TC-04-01、TC-04-02（StatusItemController 的菜单栏文案）与 TC-04-04（开机启动成败）的可单测部分。
@MainActor
struct ViewModelTests {

    @Test("TC-02-04 失败保留旧数据/异常：已有 snapshot A 时刷新失败，状态变为 failed(A, error)")
    func failureRetainsPreviousSnapshot() async {
        let usage = FakeUsageFetching { _ in validUsageJSON(usedPercent: 25) }
        let viewModel = makeViewModel(usage: usage)

        await viewModel.refresh(force: true)
        guard case .idle(let snapshotA) = viewModel.state else {
            Issue.record("首次刷新应成功进入 idle 状态，实际为 \(viewModel.state)")
            return
        }

        usage.handler = { _ in throw UserFacingError.networkUnavailable }
        await viewModel.refresh(force: true)

        guard case .failed(let retainedSnapshot, let error) = viewModel.state else {
            Issue.record("刷新失败后应进入 failed 状态，实际为 \(viewModel.state)")
            return
        }
        #expect(retainedSnapshot == snapshotA)
        #expect(error == .networkUnavailable)
    }

    @Test("TC-02-05 失败后恢复/正向：下次刷新成功后错误清空，状态变为 idle(B)")
    func recoveryClearsErrorAndAdoptsNewSnapshot() async {
        let usage = FakeUsageFetching { _ in throw UserFacingError.networkUnavailable }
        let viewModel = makeViewModel(usage: usage)

        await viewModel.refresh(force: true)
        guard case .failed = viewModel.state else {
            Issue.record("预置条件应先进入 failed 状态，实际为 \(viewModel.state)")
            return
        }

        usage.handler = { _ in validUsageJSON(usedPercent: 10) }
        await viewModel.refresh(force: true)

        guard case .idle(let snapshotB) = viewModel.state else {
            Issue.record("恢复成功后应进入 idle 状态，实际为 \(viewModel.state)")
            return
        }
        #expect(snapshotB?.windows.first?.usedPercent == 10)
    }

    @Test("TC-02-06 刷新防重/边界：连续两次手动刷新，transport 总调用数为 1")
    func concurrentManualRefreshesOnlyTriggerOneNetworkCall() async {
        let usage = FakeUsageFetching { _ in
            try await Task.sleep(for: .milliseconds(30))
            return validUsageJSON()
        }
        let viewModel = makeViewModel(usage: usage)

        async let first: () = viewModel.refresh(force: true)
        async let second: () = viewModel.refresh(force: true)
        _ = await (first, second)

        #expect(usage.callCount == 1)
        guard case .idle = viewModel.state else {
            Issue.record("两次刷新完成后应进入 idle 状态，实际为 \(viewModel.state)")
            return
        }
    }

    @Test("边界：刷新进行中调用 isRefreshInFlight 为 true，完成后恢复 false")
    func isRefreshInFlightReflectsOngoingRefresh() async {
        let usage = FakeUsageFetching { _ in
            try await Task.sleep(for: .milliseconds(30))
            return validUsageJSON()
        }
        let viewModel = makeViewModel(usage: usage)

        let refreshTask = Task { await viewModel.refresh(force: true) }
        // 让出一次执行机会，使 refresh 内部先设置 isRefreshing = true 再挂起在网络调用上。
        await Task.yield()
        #expect(viewModel.isRefreshInFlight == true)

        await refreshTask.value
        #expect(viewModel.isRefreshInFlight == false)
    }

    @Test("TC-04-01 菜单栏最紧张窗口/正向：状态项显示剩余比例最低的窗口")
    func statusItemTitleShowsTightestWindow() throws {
        let fiveHour = try makeQuotaWindow(seconds: 18_000, usedPercent: 30) // remaining = 70
        let sevenDay = try makeQuotaWindow(seconds: 604_800, usedPercent: 75) // remaining = 25
        let snapshot = QuotaSnapshot(windows: [fiveHour, sevenDay], recentTokens: .unavailable, refreshedAt: Date())

        let title = StatusItemController.title(for: .idle(snapshot))

        #expect(title == "25%")
    }

    @Test("TC-04-02 首加载/异常：无快照时 loading 显示 --")
    func loadingWithoutSnapshotShowsPlaceholder() {
        let title = StatusItemController.title(for: .loading(nil))
        #expect(title == "--")
    }

    @Test("TC-04-02 无数据错误/异常：无快照时 failed 显示 !")
    func failedWithoutSnapshotShowsErrorMarker() {
        let title = StatusItemController.title(for: .failed(nil, .networkUnavailable))
        #expect(title == "!")
    }

    @Test("TC-04-02 边界：failed 但携带旧快照时仍显示该快照的百分比，而非错误标记")
    func failedWithSnapshotShowsRetainedPercentage() throws {
        let window = try makeQuotaWindow(seconds: 604_800, usedPercent: 40) // remaining = 60
        let snapshot = QuotaSnapshot(windows: [window], recentTokens: .unavailable, refreshedAt: Date())

        let title = StatusItemController.title(for: .failed(snapshot, .networkUnavailable))

        #expect(title == "60%")
    }

    @Test("TC-04-04 开机启动成功/边界：开关变更后与系统状态一致")
    func loginItemToggleSucceeds() {
        let loginItemController = FakeLoginItemController(isEnabled: false)
        let viewModel = makeViewModel(
            usage: FakeUsageFetching { _ in validUsageJSON() },
            loginItemController: loginItemController
        )

        viewModel.setLoginItemEnabled(true)

        #expect(viewModel.isLoginItemEnabled == true)
        #expect(viewModel.loginItemErrorMessage == nil)
    }

    @Test("TC-04-04 开机启动失败/边界：失败后开关恢复为系统真实状态并显示错误")
    func loginItemToggleFailureRestoresState() {
        let loginItemController = FakeLoginItemController(isEnabled: false)
        loginItemController.errorToThrow = FakeLoginItemError()
        let viewModel = makeViewModel(
            usage: FakeUsageFetching { _ in validUsageJSON() },
            loginItemController: loginItemController
        )

        viewModel.setLoginItemEnabled(true)

        #expect(viewModel.isLoginItemEnabled == false)
        #expect(viewModel.loginItemErrorMessage != nil)
    }
}
