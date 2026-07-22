import Testing
import Foundation
@testable import CodexQuotaCore

/// 覆盖测试用例.md §2.3「Token 统计与隐私」TC-03-01 至 TC-03-03，
/// 以及 TC-03-04 中「解析产物不包含凭据/敏感内容」的可单测部分。
struct RecentTokenReaderTests {
    private let sessionsRoot = URL(fileURLWithPath: "/fake/.codex/sessions")

    private func tokenCountLine(total: Int) -> Data {
        """
        {"type":"token_count","payload":{"last_token_usage":{"total_tokens":\(total)}}}
        """.data(using: .utf8)!
    }

    @Test("TC-03-01 最近 Token/正向：返回最新文件中的计数，忽略更旧文件")
    func returnsTokenCountFromMostRecentFile() async throws {
        let fileSystem = FakeFileSystem()
        let older = sessionsRoot.appendingPathComponent("2026-01-01/old-session.jsonl")
        let newer = sessionsRoot.appendingPathComponent("2026-01-02/new-session.jsonl")

        fileSystem.setFile(older, contents: tokenCountLine(total: 999), modifiedAt: Date(timeIntervalSince1970: 1))
        fileSystem.setFile(newer, contents: tokenCountLine(total: 12345), modifiedAt: Date(timeIntervalSince1970: 2))

        let reader = JSONLRecentTokenReader(sessionsRoot: sessionsRoot, fileSystem: fileSystem)
        let result = await reader.readLatest()

        #expect(result == .value(12345))
    }

    @Test("TC-03-02 损坏/超限文件/边界：损坏行被跳过，仍能找到有效计数")
    func skipsCorruptedLinesAndFindsValidCount() async {
        let fileSystem = FakeFileSystem()
        let file = sessionsRoot.appendingPathComponent("session.jsonl")
        var content = Data()
        content.append(tokenCountLine(total: 111))
        content.append("\n".data(using: .utf8)!)
        content.append("{not valid json at all".data(using: .utf8)!)
        content.append("\n".data(using: .utf8)!)
        content.append(tokenCountLine(total: 222))
        fileSystem.setFile(file, contents: content)

        let reader = JSONLRecentTokenReader(sessionsRoot: sessionsRoot, fileSystem: fileSystem)
        let result = await reader.readLatest()

        // 从尾部向前扫描，最新一行（222）有效，直接返回，不因中间的损坏行崩溃。
        #expect(result == .value(222))
    }

    @Test("TC-03-02 边界：单文件超过 1 MiB 时只扫描有界尾部")
    func onlyScansBoundedTailOfLargeFile() async {
        let fileSystem = FakeFileSystem()
        let file = sessionsRoot.appendingPathComponent("huge-session.jsonl")

        // 构造超过 1 MiB 的文件：头部放一个不应被读到的计数，尾部放应被读到的计数。
        var content = tokenCountLine(total: 111)
        content.append("\n".data(using: .utf8)!)
        content.append(Data(repeating: UInt8(ascii: " "), count: 2 * 1_048_576))
        content.append("\n".data(using: .utf8)!)
        content.append(tokenCountLine(total: 333))
        fileSystem.setFile(file, contents: content)

        let reader = JSONLRecentTokenReader(sessionsRoot: sessionsRoot, fileSystem: fileSystem, maxBytesPerFile: 1_048_576)
        let result = await reader.readLatest()

        #expect(result == .value(333))
    }

    @Test("TC-03-03 无 Token 数据/异常：sessions 目录为空时返回 unavailable，不抛出错误")
    func emptySessionsDirectoryReturnsUnavailable() async {
        let fileSystem = FakeFileSystem()
        let reader = JSONLRecentTokenReader(sessionsRoot: sessionsRoot, fileSystem: fileSystem)

        let result = await reader.readLatest()

        #expect(result == .unavailable)
    }

    @Test("TC-03-03 异常：所有文件都没有有效计数时返回 unavailable")
    func noValidCountReturnsUnavailable() async {
        let fileSystem = FakeFileSystem()
        let file = sessionsRoot.appendingPathComponent("session.jsonl")
        fileSystem.setFile(file, contents: "{\"type\":\"other_event\"}".data(using: .utf8)!)

        let reader = JSONLRecentTokenReader(sessionsRoot: sessionsRoot, fileSystem: fileSystem)
        let result = await reader.readLatest()

        #expect(result == .unavailable)
    }

    @Test("TC-03-04 隐私/异常：即便行中含有假 token 字符串，解析结果也只包含数字，不包含 token 原文")
    func extractedResultNeverContainsTokenString() {
        // 用一个明显不合法的事件类型 + 假 token 字段验证：解析器既不识别该事件，也不会把假 token 值带出。
        let line = """
        {"type":"session_meta","auth_snapshot":"\(fakeAccessToken)"}
        """.data(using: .utf8)!

        let count = TokenCountExtractor.extract(from: line)

        // RecentTokenResult/TokenCountExtractor 的返回类型本身就是 Int?，结构上不可能携带字符串凭据；
        // 这里额外断言事件类型不匹配时直接返回 nil，验证解析器确实没有读取该字段。
        #expect(count == nil)
    }

    @Test("TokenCountExtractor 单测：非 Token 事件类型被忽略")
    func extractorIgnoresUnrelatedEventTypes() {
        let line = "{\"type\":\"user_message\",\"last_token_usage\":{\"total_tokens\":42}}".data(using: .utf8)!

        #expect(TokenCountExtractor.extract(from: line) == nil)
    }
}
