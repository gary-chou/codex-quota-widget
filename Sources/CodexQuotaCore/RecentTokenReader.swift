import Foundation

/// RecentTokenReading 定义读取“最近一次任务 Token 计数”的能力，供 `QuotaRefreshCoordinator` 注入使用。
public protocol RecentTokenReading {
    /// RecentTokenReading.readLatest 返回最近任务的 Token 数字；不可用时返回 `.unavailable`，不抛出错误。
    ///
    /// Token 读取失败不应影响额度快照的产生（技术方案 §3.7），因此本方法不声明 `throws`。
    func readLatest() async -> RecentTokenResult
}

/// TokenCountExtractor 只从单行 JSONL 事件中提取 Token 计数，不解析标题、正文或用户输入字段。
public enum TokenCountExtractor {
    /// 只识别这些事件类型，避免遍历与 Token 统计无关（可能包含对话内容）的事件。
    private static let relevantEventTypes: Set<String> = ["token_count", "event_msg"]
    /// 递归查找 `last_token_usage` 的最大深度，避免对畸形/超深嵌套 JSON 做无界递归。
    private static let maxSearchDepth = 4

    /// TokenCountExtractor.extract 从单行 JSONL 数据中提取 `last_token_usage.total_tokens`；找不到则返回 nil。
    public static func extract(from line: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String, relevantEventTypes.contains(type) else {
            return nil
        }
        return findTotalTokens(in: json, depth: 0)
    }

    private static func findTotalTokens(in object: [String: Any], depth: Int) -> Int? {
        if let usage = object["last_token_usage"] as? [String: Any] {
            if let total = usage["total_tokens"] as? Int {
                return total
            }
            if let total = usage["total_tokens"] as? Double {
                return Int(total)
            }
        }
        guard depth < maxSearchDepth else { return nil }
        for value in object.values {
            if let nested = value as? [String: Any],
               let found = findTotalTokens(in: nested, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}

/// JSONLRecentTokenReader 在 `~/.codex/sessions/**/*.jsonl` 中查找最近任务的 Token 计数。
///
/// 边界策略（技术方案 §3.4）：
/// - 只查看按修改时间排序的最新 N 个 JSONL 文件（默认 10 个）。
/// - 每个文件只从尾部读取最多 1 MiB，避免一次性把整份大文件读入内存。
/// - 在该有界窗口内从最新一行向前扫描，命中第一个有效计数即返回；找不到则视为不可用。
public struct JSONLRecentTokenReader: RecentTokenReading {
    private let sessionsRoot: URL
    private let fileSystem: FileSystemProviding
    private let maxFilesScanned: Int
    private let maxBytesPerFile: Int

    /// JSONLRecentTokenReader.init 以 `sessionsRoot`（默认 `~/.codex/sessions`）为根目录查找任务文件。
    public init(
        sessionsRoot: URL,
        fileSystem: FileSystemProviding = DefaultFileSystem(),
        maxFilesScanned: Int = 10,
        maxBytesPerFile: Int = 1_048_576
    ) {
        self.sessionsRoot = sessionsRoot
        self.fileSystem = fileSystem
        self.maxFilesScanned = maxFilesScanned
        self.maxBytesPerFile = maxBytesPerFile
    }

    public func readLatest() async -> RecentTokenResult {
        let candidates = fileSystem.enumerateFiles(under: sessionsRoot)
            .filter { $0.url.pathExtension.lowercased() == "jsonl" }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFilesScanned)

        for candidate in candidates {
            guard let tail = fileSystem.readTail(of: candidate.url, maxBytes: maxBytesPerFile) else {
                continue
            }
            if let count = latestTokenCount(inTail: tail) {
                return .value(count)
            }
        }
        return .unavailable
    }

    /// 在有界尾部数据中按行反向扫描（越靠近文件尾部代表越新），容忍个别损坏行，命中即停止。
    private func latestTokenCount(inTail data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let count = TokenCountExtractor.extract(from: lineData) {
                return count
            }
        }
        return nil
    }
}
