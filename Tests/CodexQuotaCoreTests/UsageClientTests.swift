import Testing
import Foundation
@testable import CodexQuotaCore

/// 覆盖测试用例.md TC-02-01、TC-02-02 与 TC-02-03 中「认证过期」的可单测部分。
struct UsageClientTests {
    private let auth = CodexAuth(accessToken: fakeAccessToken, accountID: "fake-account-id")

    @Test("TC-02-01 正常刷新/正向：200 响应体被原样透传给调用方")
    func successfulFetchReturnsBody() async throws {
        let expectedBody = "{\"rate_limit\":{}}".data(using: .utf8)!
        let transport = FakeHTTPTransport(script: .respond(statusCode: 200, body: expectedBody))
        let client = UsageClient(transport: transport)

        let data = try await client.fetch(auth: auth)

        #expect(data == expectedBody)
        #expect(transport.callCount == 1)
    }

    @Test("TC-02-02 请求头最小化/正向：URL、方法、Bearer 与可选 account id 均正确，且无多余敏感头")
    func requestHeadersAreMinimal() async throws {
        let transport = FakeHTTPTransport(script: .respond(statusCode: 200, body: Data()))
        let client = UsageClient(transport: transport)

        _ = try await client.fetch(auth: auth)

        let request = try #require(transport.capturedRequests.first)
        #expect(request.url == UsageClient.usageURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeAccessToken)")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fake-account-id")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // 只应包含以上三个头部字段，不夹带 Cookie 等其他敏感信息。
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys) == ["Authorization", "Accept", "ChatGPT-Account-Id"])
    }

    @Test("请求头最小化/边界：account id 缺失时不设置对应头部")
    func accountHeaderOmittedWhenNoAccountID() async throws {
        let transport = FakeHTTPTransport(script: .respond(statusCode: 200, body: Data()))
        let client = UsageClient(transport: transport)
        let authWithoutAccount = CodexAuth(accessToken: fakeAccessToken, accountID: nil)

        _ = try await client.fetch(auth: authWithoutAccount)

        let request = try #require(transport.capturedRequests.first)
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test("TC-02-03 认证过期/异常：401 映射为 authenticationExpired")
    func unauthorizedMapsToAuthenticationExpired() async {
        let transport = FakeHTTPTransport(script: .respond(statusCode: 401, body: Data()))
        let client = UsageClient(transport: transport)

        await #expect(throws: UserFacingError.authenticationExpired) {
            try await client.fetch(auth: auth)
        }
    }

    @Test("TC-02-03 认证过期/异常：403 同样映射为 authenticationExpired")
    func forbiddenMapsToAuthenticationExpired() async {
        let transport = FakeHTTPTransport(script: .respond(statusCode: 403, body: Data()))
        let client = UsageClient(transport: transport)

        await #expect(throws: UserFacingError.authenticationExpired) {
            try await client.fetch(auth: auth)
        }
    }

    @Test("异常：其他 5xx 状态码映射为 networkUnavailable，不泄露响应体")
    func serverErrorMapsToNetworkUnavailable() async {
        let transport = FakeHTTPTransport(script: .respond(statusCode: 500, body: "server internals".data(using: .utf8)!))
        let client = UsageClient(transport: transport)

        await #expect(throws: UserFacingError.networkUnavailable) {
            try await client.fetch(auth: auth)
        }
    }

    @Test("异常：传输层错误（超时/断网）映射为 networkUnavailable")
    func transportErrorMapsToNetworkUnavailable() async {
        let transport = FakeHTTPTransport(script: .throwError(FakeTransportError()))
        let client = UsageClient(transport: transport)

        await #expect(throws: UserFacingError.networkUnavailable) {
            try await client.fetch(auth: auth)
        }
    }
}
