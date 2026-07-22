import Foundation

/// HTTPTransport 隔离底层网络请求执行，测试时可注入返回固定响应的 stub，无需真实联网。
public protocol HTTPTransport {
    /// HTTPTransport.data 发起请求并返回响应体与 HTTP 响应；不在实现中打印请求头或响应体。
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 基于 `URLSession` 的默认传输实现。
///
/// 使用 `.ephemeral` 会话配置：不写磁盘缓存、不持久化 Cookie，降低认证信息落盘的风险。
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UserFacingError.networkUnavailable
        }
        return (data, httpResponse)
    }
}

/// UsageFetching 定义获取用量原始响应体的能力，供 `QuotaRefreshCoordinator` 注入使用。
public protocol UsageFetching {
    /// UsageFetching.fetch 使用给定凭据请求用量接口，返回原始响应体（交由 `UsageParser` 解析）。
    func fetch(auth: CodexAuth) async throws -> Data
}

/// UsageClient 组装并发起 `GET https://chatgpt.com/backend-api/wham/usage` 请求。
///
/// 只设置 `Authorization`、可选 account id 与标准 `Accept` 头；不设置、不记录任何其他敏感头部。
public struct UsageClient: UsageFetching {
    /// Codex 客户端当前使用的内部用量端点；不是稳定公开 API（技术方案 §4 备注）。
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// 请求头字段名：可选的账号标识，仅在凭据携带 account id 时才会设置。
    private static let accountHeaderField = "ChatGPT-Account-Id"

    private let transport: HTTPTransport
    private let timeout: TimeInterval

    /// UsageClient.init 允许注入自定义传输层与超时时长（默认 10 秒，符合技术方案 §3.3）。
    public init(transport: HTTPTransport = URLSessionHTTPTransport(), timeout: TimeInterval = 10) {
        self.transport = transport
        self.timeout = timeout
    }

    public func fetch(auth: CodexAuth) async throws -> Data {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: Self.accountHeaderField)
        }

        do {
            let (data, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                // 认证失效：不展示、不记录响应体，只返回语义化错误。
                throw UserFacingError.authenticationExpired
            default:
                throw UserFacingError.networkUnavailable
            }
        } catch let error as UserFacingError {
            throw error
        } catch {
            // 超时、断网等传输层错误统一映射为“网络不可用”，不泄露底层错误细节。
            throw UserFacingError.networkUnavailable
        }
    }
}
