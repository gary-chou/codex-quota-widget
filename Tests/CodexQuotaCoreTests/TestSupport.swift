import Foundation
@testable import CodexQuotaCore

// MARK: - 测试专用假数据与测试替身
//
// 隐私红线（对应 TC-03-04）：本文件中出现的 token/cookie 一律使用明显不可用的假值，
// 命名中带有 "fake" 前缀，绝不使用任何真实或可打印的生产凭据格式。

/// 供全部测试复用的明显虚假 access token；TC-03-04 断言该字符串不会出现在任何解析产物中。
let fakeAccessToken = "sk-test-FAKE0000000000000000000000notarealtoken"

/// 供全部测试复用的明显虚假 cookie 值。
let fakeCookieValue = "session=FAKE-COOKIE-VALUE-NOT-REAL; Path=/"

/// FakeFileSystem 是 `FileSystemProviding` 的内存实现，供 AuthStore / RecentTokenReader 测试注入。
final class FakeFileSystem: FileSystemProviding, @unchecked Sendable {
    private(set) var files: [URL: Data] = [:]
    private var modificationDates: [URL: Date] = [:]

    func setFile(_ url: URL, contents: Data, modifiedAt: Date = Date()) {
        files[url] = contents
        modificationDates[url] = modifiedAt
    }

    func data(at url: URL) throws -> Data {
        guard let data = files[url] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func fileExists(at url: URL) -> Bool {
        files[url] != nil
    }

    func enumerateFiles(under directory: URL) -> [(url: URL, modifiedAt: Date)] {
        files.keys
            .filter { $0.path.hasPrefix(directory.path) }
            .map { ($0, modificationDates[$0] ?? .distantPast) }
    }

    func readTail(of url: URL, maxBytes: Int) -> Data? {
        guard let data = files[url] else { return nil }
        if data.count <= maxBytes { return data }
        return data.suffix(maxBytes)
    }
}

/// FakeHTTPTransport 记录收到的请求，并按预设脚本返回响应或抛出错误，避免真实联网。
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    enum Script {
        case respond(statusCode: Int, body: Data)
        case throwError(Error)
    }

    private(set) var capturedRequests: [URLRequest] = []
    private(set) var callCount = 0
    var script: Script

    init(script: Script) {
        self.script = script
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        callCount += 1
        switch script {
        case .respond(let statusCode, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        case .throwError(let error):
            throw error
        }
    }
}

/// FakeAuthProviding 按预设结果返回凭据或抛出错误。
struct FakeAuthProviding: AuthProviding {
    let result: Result<CodexAuth, Error>

    func load() throws -> CodexAuth {
        try result.get()
    }
}

/// FakeUsageFetching 记录调用次数，并按闭包生成结果，供刷新协调器测试注入。
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

/// FakeClock 返回固定时间，便于断言 `refreshedAt`。
struct FakeClock: ClockProviding {
    let fixedDate: Date

    func now() -> Date { fixedDate }
}

/// 一个简单的传输层错误，模拟超时/断网等场景，不携带任何服务端响应信息。
struct FakeTransportError: Error {}
