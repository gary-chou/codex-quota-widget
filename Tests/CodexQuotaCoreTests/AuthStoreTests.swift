import Testing
import Foundation
@testable import CodexQuotaCore

/// 覆盖测试用例.md TC-02-03 中「未找到本机登录信息」的可单测部分，
/// 以及 `FileAuthStore` 对 `auth.json` 的最小化容错解析。
struct AuthStoreTests {
    private let codexHome = URL(fileURLWithPath: "/fake/.codex")

    @Test("正向：顶层 access_token/account_id 字段可被正确读取")
    func loadsTopLevelAccessTokenAndAccountID() throws {
        let fileSystem = FakeFileSystem()
        let json = """
        {"access_token":"\(fakeAccessToken)","account_id":"fake-account-id"}
        """.data(using: .utf8)!
        fileSystem.setFile(codexHome.appendingPathComponent("auth.json"), contents: json)

        let store = FileAuthStore(codexHome: codexHome, fileSystem: fileSystem)
        let auth = try store.load()

        #expect(auth.accessToken == fakeAccessToken)
        #expect(auth.accountID == "fake-account-id")
    }

    @Test("正向：嵌套 tokens.access_token 结构同样可被读取")
    func loadsNestedTokensAccessToken() throws {
        let fileSystem = FakeFileSystem()
        let json = """
        {"tokens":{"access_token":"\(fakeAccessToken)","account_id":"fake-account-id"}}
        """.data(using: .utf8)!
        fileSystem.setFile(codexHome.appendingPathComponent("auth.json"), contents: json)

        let store = FileAuthStore(codexHome: codexHome, fileSystem: fileSystem)
        let auth = try store.load()

        #expect(auth.accessToken == fakeAccessToken)
        #expect(auth.accountID == "fake-account-id")
    }

    @Test("TC-02-03 未登录/异常：auth.json 文件缺失时抛出 notSignedIn")
    func missingAuthFileThrowsNotSignedIn() {
        let fileSystem = FakeFileSystem()
        let store = FileAuthStore(codexHome: codexHome, fileSystem: fileSystem)

        #expect(throws: AuthError.notSignedIn) {
            try store.load()
        }
    }

    @Test("异常：auth.json 存在但缺少 access_token 时抛出 notSignedIn，不抛出解析细节")
    func malformedAuthFileThrowsNotSignedIn() {
        let fileSystem = FakeFileSystem()
        fileSystem.setFile(
            codexHome.appendingPathComponent("auth.json"),
            contents: "{\"unexpected\":true}".data(using: .utf8)!
        )
        let store = FileAuthStore(codexHome: codexHome, fileSystem: fileSystem)

        #expect(throws: AuthError.notSignedIn) {
            try store.load()
        }
    }

    @Test("异常：auth.json 内容不是合法 JSON 时抛出 notSignedIn")
    func nonJSONAuthFileThrowsNotSignedIn() {
        let fileSystem = FakeFileSystem()
        fileSystem.setFile(
            codexHome.appendingPathComponent("auth.json"),
            contents: "not json".data(using: .utf8)!
        )
        let store = FileAuthStore(codexHome: codexHome, fileSystem: fileSystem)

        #expect(throws: AuthError.notSignedIn) {
            try store.load()
        }
    }
}
