import Foundation

/// ClockProviding 隔离“当前时间”的获取，使刷新时间等逻辑可在单元测试中被固定。
public protocol ClockProviding {
    func now() -> Date
}

/// 基于系统时钟的默认实现。
public struct SystemClock: ClockProviding {
    public init() {}
    public func now() -> Date { Date() }
}

/// 一次刷新的结果：成功产生新快照，或失败并携带面向用户的错误。
public enum RefreshOutcome: Equatable {
    case success(QuotaSnapshot)
    case failure(UserFacingError)
}

/// QuotaRefreshCoordinator 聚合“认证 -> 请求额度 -> 解析”与“读取最近 Token”两条链路。
///
/// 并发策略（技术方案 §3.5、§3.7）：额度请求与 Token 读取并发执行；额度请求成功即产生快照
/// （快照提交边界），Token 读取失败只让该字段标记为不可用，属于部分成功，不影响额度展示。
public struct QuotaRefreshCoordinator {
    private let appServerClient: AppServerUsageFetching?
    private let authStore: AuthProviding
    private let usageClient: UsageFetching
    private let tokenReader: RecentTokenReading
    private let clock: ClockProviding

    public init(
        appServerClient: AppServerUsageFetching? = nil,
        authStore: AuthProviding,
        usageClient: UsageFetching,
        tokenReader: RecentTokenReading,
        clock: ClockProviding = SystemClock()
    ) {
        self.appServerClient = appServerClient
        self.authStore = authStore
        self.usageClient = usageClient
        self.tokenReader = tokenReader
        self.clock = clock
    }

    /// QuotaRefreshCoordinator.refresh 执行一次完整刷新，返回成功快照或面向用户的错误。
    public func refresh() async -> RefreshOutcome {
        // Token 读取与额度请求并发执行，二者互不阻塞；Token 结果无论成功与否都必须被消费，
        // 避免遗留未等待的子任务。
        async let tokenResultTask = tokenReader.readLatest()

        do {
            let windows = try await fetchWindowsWithFallback()
            let tokens = await tokenResultTask
            let snapshot = QuotaSnapshot(windows: windows, recentTokens: tokens, refreshedAt: clock.now())
            return .success(snapshot)
        } catch let error as UserFacingError {
            _ = await tokenResultTask
            return .failure(error)
        } catch {
            _ = await tokenResultTask
            return .failure(.networkUnavailable)
        }
    }

    private func fetchWindowsWithFallback() async throws -> [QuotaWindow] {
        var appServerError: Error?
        if let appServerClient {
            do {
                let data = try await appServerClient.fetch()
                do {
                    return try UsageParser.parse(data)
                } catch {
                    // 可序列化并不等于协议兼容；无有效窗口时仍应尝试旧链路。
                    throw CodexAppServerError.incompatible
                }
            } catch {
                // app-server 是首选但不是单点依赖；旧版 CLI 或进程不可用时仍允许文件认证继续工作。
                appServerError = error
            }
        }

        do {
            let auth = try authStore.load()
            let data = try await usageClient.fetch(auth: auth)
            return try UsageParser.parse(data)
        } catch AuthError.notSignedIn {
            guard let appServerError else { throw UserFacingError.notSignedIn }
            switch appServerError {
            case CodexAppServerError.timedOut, CodexAppServerError.unavailable:
                throw UserFacingError.networkUnavailable
            case CodexAppServerError.binaryNotFound, CodexAppServerError.incompatible:
                throw UserFacingError.notSignedIn
            default:
                throw UserFacingError.networkUnavailable
            }
        }
    }
}

/// RefreshScheduler 按固定周期重复调用刷新动作，启动后立即执行一次。
///
/// 实现为 `actor` 以保护内部的定时任务句柄，允许从任意上下文安全地 `start`/`stop`。
public actor RefreshScheduler {
    private var task: Task<Void, Never>?

    public init() {}

    /// RefreshScheduler.start 启动即执行一次 `action`，随后每隔 `interval` 重复执行，直到 `stop()`。
    ///
    /// 重复调用 `start` 会先取消旧的定时任务，避免出现多条并行的刷新循环。
    public func start(interval: Duration, action: @escaping () async -> Void) {
        stop()
        task = Task {
            while !Task.isCancelled {
                await action()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    // 任务被取消（stop）时 Task.sleep 会抛出 CancellationError，正常退出循环即可。
                    break
                }
            }
        }
    }

    /// RefreshScheduler.stop 取消当前定时任务；重复调用是安全的空操作。
    public func stop() {
        task?.cancel()
        task = nil
    }
}
