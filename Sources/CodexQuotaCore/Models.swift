import Foundation

// MARK: - Raw wire types (来自 Codex 用量接口的容错解码模型)
//
// 设计原则（对应技术方案 §3.2、知识背景「可复用结论」）：
// - 不依赖 `primary_window` / `secondary_window` 的位置含义，解析后统一打平为窗口数组。
// - 任一字段缺失、为 `null` 或类型不匹配都不能让整份响应解码失败；只应影响该字段/该窗口。
// - 解码结构本身不定义标题、正文或用户输入字段，避免任何隐私数据被引入内存模型。

/// `GET /backend-api/wham/usage` 响应的顶层容器，仅承载额度限制字段。
///
/// 容错策略：优先按技术方案 §3.2 约定的 `rate_limit` 键解码；本机 `~/.codex/sessions` 中
/// 观测到 Codex CLI 自身事件日志使用的是 `rate_limits`（复数）容器，为降低该内部端点
/// 演进/命名差异带来的解析失败风险，两种键名都会被尝试，互不冲突（知识背景「解析层必须
/// 宽容且可测试」）。忽略响应中的其他未知字段（`Decodable` 默认行为）。
public struct RawUsageResponse: Decodable {
    public let rateLimit: RawRateLimit?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case rateLimitsAlternate = "rate_limits"
        case rateLimitsAppServer = "rateLimits"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try? container.decodeIfPresent(RawRateLimit.self, forKey: .rateLimit)
        let alternate = try? container.decodeIfPresent(RawRateLimit.self, forKey: .rateLimitsAlternate)
        let appServer = try? container.decodeIfPresent(RawRateLimit.self, forKey: .rateLimitsAppServer)
        rateLimit = primary ?? alternate ?? appServer
    }
}

/// `rate_limit`/`rate_limits` 节点，承载主/次两个候选窗口容器。
///
/// 主次位置仅作为原始 JSON 的候选容器，不代表窗口的真实含义；真实含义由
/// `QuotaWindowKind.classify(seconds:)` 依据窗口时长判定。同时兼容 `primary_window`/
/// `secondary_window`（技术方案 §3.2）与 `primary`/`secondary`（本机观测到的实际命名）两种键名。
public struct RawRateLimit: Decodable {
    public let primaryWindow: RawRateLimitWindow?
    public let secondaryWindow: RawRateLimitWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case primaryWindowAlternate = "primary"
        case secondaryWindow = "secondary_window"
        case secondaryWindowAlternate = "secondary"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try? container.decodeIfPresent(RawRateLimitWindow.self, forKey: .primaryWindow)
        let primaryAlternate = try? container.decodeIfPresent(RawRateLimitWindow.self, forKey: .primaryWindowAlternate)
        primaryWindow = primary ?? primaryAlternate

        let secondary = try? container.decodeIfPresent(RawRateLimitWindow.self, forKey: .secondaryWindow)
        let secondaryAlternate = try? container.decodeIfPresent(RawRateLimitWindow.self, forKey: .secondaryWindowAlternate)
        secondaryWindow = secondary ?? secondaryAlternate
    }
}

/// 单个额度窗口的原始字段，所有字段均以“尽力而为”方式解码。
///
/// 任何字段类型不匹配（例如 `used_percent` 是字符串而非数字）只会让该字段变为 `nil`，
/// 不会抛出解码错误，从而避免旧版应用中因 `NSNull` 下标访问导致崩溃的同类问题。
///
/// 窗口时长与重置时间同时兼容两种命名：技术方案 §3.2 约定的 `limit_window_seconds`/`reset_at`，
/// 以及本机观测到的 `window_minutes`（分钟，需换算为秒）/`resets_at`（Unix 秒）。
public struct RawRateLimitWindow: Decodable {
    public let usedPercent: Double?
    public let limitWindowSeconds: Int?
    public let resetAt: Date?

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case usedPercentAppServer = "usedPercent"
        case limitWindowSeconds = "limit_window_seconds"
        case windowMinutes = "window_minutes"
        case windowDurationMinutesAppServer = "windowDurationMins"
        case resetAt = "reset_at"
        case resetsAtAlternate = "resets_at"
        case resetsAtAppServer = "resetsAt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.decodeLenientDouble(forKey: .usedPercent)
            ?? container.decodeLenientDouble(forKey: .usedPercentAppServer)

        if let seconds = container.decodeLenientInt(forKey: .limitWindowSeconds) {
            limitWindowSeconds = seconds
        } else if let minutes = container.decodeLenientInt(forKey: .windowMinutes) {
            // 观测到的实际事件日志以分钟为单位表示窗口时长，统一换算为秒以复用同一套窗口归类逻辑。
            limitWindowSeconds = minutes * 60
        } else if let minutes = container.decodeLenientInt(forKey: .windowDurationMinutesAppServer) {
            // app-server 使用 camelCase 的分钟字段，尽早归一化以保持领域模型与 UI 无需感知来源。
            limitWindowSeconds = minutes * 60
        } else {
            limitWindowSeconds = nil
        }

        if let date = container.decodeLenientDate(forKey: .resetAt) {
            resetAt = date
        } else if let date = container.decodeLenientDate(forKey: .resetsAtAppServer) {
            resetAt = date
        } else {
            resetAt = container.decodeLenientDate(forKey: .resetsAtAlternate)
        }
    }

    /// 供单元测试直接构造 fixture，避免每个用例都经过 JSON 编解码。
    public init(usedPercent: Double?, limitWindowSeconds: Int?, resetAt: Date?) {
        self.usedPercent = usedPercent
        self.limitWindowSeconds = limitWindowSeconds
        self.resetAt = resetAt
    }
}

/// 为 `KeyedDecodingContainer` 提供“类型不匹配不抛错、只返回 nil”的宽容解码辅助方法。
///
/// 用量接口是 Codex 客户端使用的内部端点（技术方案 §4 备注），响应结构可能演进，
/// 因此单个字段的类型异常不应传播为整份响应解析失败。
extension KeyedDecodingContainer {
    func decodeLenientDouble(forKey key: Key) -> Double? {
        // `try?` 会自动展平 `decodeIfPresent` 本身返回的 Optional，因此这里拿到的已经是非可选值。
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        return nil
    }

    func decodeLenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    func decodeLenientDate(forKey key: Key) -> Date? {
        // 依次尝试：Unix 时间戳（秒，数值）、ISO8601 字符串；两者都失败则视为缺失，不影响窗口本身展示。
        if let seconds = try? decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}

// MARK: - Domain models (供 UI 直接消费的不可变模型)

/// 额度窗口的时长归类，依据窗口秒数判定，不依赖字段在 JSON 中的主次位置。
public enum QuotaWindowKind: Equatable, Sendable {
    /// 5 小时窗口（18,000 秒）。
    case fiveHour
    /// 7 天窗口（604,800 秒）。
    case sevenDay
    /// 其他未预期的时长，按秒数保留为自定义窗口，避免新窗口类型导致应用失效。
    case custom(seconds: Int)

    /// QuotaWindowKind.classify 依据窗口秒数归类：18,000 秒为 5 小时，604,800 秒为 7 天，其余为自定义窗口。
    public static func classify(seconds: Int) -> QuotaWindowKind {
        switch seconds {
        case 18_000:
            return .fiveHour
        case 604_800:
            return .sevenDay
        default:
            return .custom(seconds: seconds)
        }
    }

    /// 面向界面展示的简短标签，例如 `5h`、`7d`、`1d`（自定义窗口按天/小时/秒选择最合适的单位）。
    public var displayLabel: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .sevenDay:
            return "7d"
        case .custom(let seconds):
            if seconds % 86_400 == 0 {
                return "\(seconds / 86_400)d"
            }
            if seconds % 3_600 == 0 {
                return "\(seconds / 3_600)h"
            }
            return "\(seconds)s"
        }
    }
}

/// 校验通过后的单个额度窗口，供 UI 直接消费。
public struct QuotaWindow: Equatable, Sendable, Identifiable {
    public let kind: QuotaWindowKind
    /// 已用百分比，已被限制在 0...100 区间内。
    public let usedPercent: Double
    /// 剩余百分比，等于 `100 - usedPercent`。
    public let remainingPercent: Double
    public let windowSeconds: Int
    public let resetAt: Date?

    public var id: String { kind.displayLabel + "-\(windowSeconds)" }

    /// QuotaWindow 校验失败原因；任一原因都会导致该窗口被 `UsageParser` 整体跳过，而不影响其他窗口。
    public enum ValidationError: Error, Equatable, Sendable {
        /// 窗口时长缺失或非法（非正数），无法归类窗口种类。
        case missingWindowSeconds
        /// `used_percent` 缺失或不是数值类型。
        case nonNumericUsedPercent
    }

    /// QuotaWindow.init(raw:) 校验原始窗口字段：时长必须为正数，`used_percent` 必须是数值并被夹到 0...100。
    public init(raw: RawRateLimitWindow) throws {
        guard let seconds = raw.limitWindowSeconds, seconds > 0 else {
            throw ValidationError.missingWindowSeconds
        }
        guard let rawUsed = raw.usedPercent else {
            throw ValidationError.nonNumericUsedPercent
        }
        let clamped = min(max(rawUsed, 0), 100)
        self.usedPercent = clamped
        self.remainingPercent = 100 - clamped
        self.windowSeconds = seconds
        self.kind = QuotaWindowKind.classify(seconds: seconds)
        self.resetAt = raw.resetAt
    }
}

/// 最近一次成功任务的 Token 统计结果；只承载数字，不承载任务标题、正文或用户输入。
public enum RecentTokenResult: Equatable, Sendable {
    case value(Int)
    case unavailable
}

/// 一次刷新成功后的不可变快照，界面据此渲染菜单栏、详情面板与悬浮窗。
public struct QuotaSnapshot: Equatable, Sendable {
    public let windows: [QuotaWindow]
    public let recentTokens: RecentTokenResult
    public let refreshedAt: Date

    public init(windows: [QuotaWindow], recentTokens: RecentTokenResult, refreshedAt: Date) {
        self.windows = windows
        self.recentTokens = recentTokens
        self.refreshedAt = refreshedAt
    }

    /// 剩余比例最低（最紧张）的窗口，用于菜单栏优先展示（结构化需求 §3.1）。
    public var tightestWindow: QuotaWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }
}

/// 面向用户展示的错误类型；文案不包含服务端响应原文、认证凭据或请求头内容。
public enum UserFacingError: Error, Equatable, Sendable {
    /// 本机未找到 Codex 登录凭据。
    case notSignedIn
    /// 认证已失效（HTTP 401/403）。
    case authenticationExpired
    /// 网络超时、断网或传输层错误。
    case networkUnavailable
    /// 响应中没有任何可用的额度窗口。
    case invalidUsageResponse

    /// 面向用户的简短说明，刻意不包含任何服务端响应原文或凭据片段。
    public var userMessage: String {
        switch self {
        case .notSignedIn:
            return "未检测到 Codex 登录信息，请先登录 Codex 后重试。"
        case .authenticationExpired:
            return "登录已失效，请重新登录 Codex。"
        case .networkUnavailable:
            return "网络不可用或请求超时，请检查网络后重试。"
        case .invalidUsageResponse:
            return "额度数据暂不可用，请稍后重试。"
        }
    }

    /// 是否应在界面上提供“重试”入口；当前所有错误类型都允许重试。
    public var isRetryable: Bool { true }
}

/// 应用界面状态机（结构化需求 §5、技术方案 §3.5）。
///
/// - `loading`：正在刷新，可能携带上一次的成功快照（保留旧数据展示）。
/// - `idle`：最近一次刷新成功，携带最新快照；无快照代表尚未有任何成功结果。
/// - `failed`：最近一次刷新失败，携带最近一次成功快照（如有）与错误信息。
public enum ViewState: Equatable, Sendable {
    case loading(QuotaSnapshot?)
    case idle(QuotaSnapshot?)
    case failed(QuotaSnapshot?, UserFacingError)

    /// 当前状态下可展示的快照（无论处于哪种状态，只要曾经成功过就应保留展示）。
    public var snapshot: QuotaSnapshot? {
        switch self {
        case .loading(let snapshot), .idle(let snapshot), .failed(let snapshot, _):
            return snapshot
        }
    }
}
