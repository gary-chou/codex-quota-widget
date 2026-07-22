import Foundation

/// 本机 Codex 登录凭据的最小化表示。
///
/// 仅保留发起用量请求所必需的字段；不持久化、不记录日志、不在错误信息中回显。
public struct CodexAuth: Equatable {
    public let accessToken: String
    public let accountID: String?

    public init(accessToken: String, accountID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

/// 读取本机登录凭据可能出现的错误。
public enum AuthError: Error, Equatable {
    /// 未找到凭据文件，或文件存在但无法解析出可用的 access token。
    case notSignedIn
}

/// AuthProviding 定义获取当前本机登录凭据的能力，供 `QuotaRefreshCoordinator` 注入使用。
public protocol AuthProviding {
    /// AuthProviding.load 读取并返回当前登录凭据；无凭据或凭据不可用时抛出 `AuthError.notSignedIn`。
    func load() throws -> CodexAuth
}

/// FileSystemProviding 隔离文件系统访问，使 Core 层可在不接触真实磁盘的情况下完成单元测试。
///
/// 同时被 `FileAuthStore` 与 `JSONLRecentTokenReader` 复用，避免定义两套读文件协议。
public protocol FileSystemProviding {
    /// 读取指定文件的完整内容。
    func data(at url: URL) throws -> Data
    /// 指定路径是否存在（文件或目录）。
    func fileExists(at url: URL) -> Bool
    /// 递归枚举目录下的所有常规文件，返回文件 URL 与最后修改时间；目录不存在或不可读时返回空数组，不抛出错误。
    func enumerateFiles(under directory: URL) -> [(url: URL, modifiedAt: Date)]
    /// 从文件尾部读取最多 `maxBytes` 字节，用于对可能很大的本地文件做有界读取；读取失败返回 `nil`。
    func readTail(of url: URL, maxBytes: Int) -> Data?
}

/// 基于 `FileManager`/`FileHandle` 的默认文件系统实现，供生产环境使用。
public struct DefaultFileSystem: FileSystemProviding {
    public init() {}

    public func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func enumerateFiles(under directory: URL) -> [(url: URL, modifiedAt: Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(url: URL, modifiedAt: Date)] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            results.append((url: fileURL, modifiedAt: values.contentModificationDate ?? .distantPast))
        }
        return results
    }

    public func readTail(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }
}

/// FileAuthStore 只读取 `~/.codex/auth.json`，从中最小化解析出 access token 与可选的 account id。
///
/// 只在内存中短暂持有解析结果，不缓存、不写日志（知识背景「认证信息只能在内存中短暂使用」）。
public struct FileAuthStore: AuthProviding {
    private let authFileURL: URL
    private let fileSystem: FileSystemProviding

    /// FileAuthStore.init 以 `codexHome`（默认 `~/.codex`）定位 `auth.json`；`fileSystem` 供测试注入。
    public init(codexHome: URL, fileSystem: FileSystemProviding = DefaultFileSystem()) {
        self.authFileURL = codexHome.appendingPathComponent("auth.json")
        self.fileSystem = fileSystem
    }

    public func load() throws -> CodexAuth {
        guard fileSystem.fileExists(at: authFileURL) else {
            throw AuthError.notSignedIn
        }

        let data: Data
        do {
            data = try fileSystem.data(at: authFileURL)
        } catch {
            throw AuthError.notSignedIn
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.notSignedIn
        }

        guard let accessToken = Self.extractAccessToken(from: json), !accessToken.isEmpty else {
            throw AuthError.notSignedIn
        }

        return CodexAuth(accessToken: accessToken, accountID: Self.extractAccountID(from: json))
    }

    /// 只提取 access token 所需的字段，兼容 Codex 客户端 `auth.json` 的顶层与 `tokens` 嵌套两种已知形状。
    private static func extractAccessToken(from json: [String: Any]) -> String? {
        if let token = json["access_token"] as? String {
            return token
        }
        if let tokens = json["tokens"] as? [String: Any], let token = tokens["access_token"] as? String {
            return token
        }
        return nil
    }

    private static func extractAccountID(from json: [String: Any]) -> String? {
        if let id = json["account_id"] as? String {
            return id
        }
        if let tokens = json["tokens"] as? [String: Any], let id = tokens["account_id"] as? String {
            return id
        }
        return nil
    }
}
