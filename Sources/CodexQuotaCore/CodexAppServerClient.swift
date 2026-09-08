import Foundation

/// AppServerUsageFetching 定义通过 Codex app-server 读取当前账号额度的能力。
public protocol AppServerUsageFetching {
    /// AppServerUsageFetching.fetch 启动一次隔离的 app-server 会话并返回额度结果 JSON。
    func fetch() async throws -> Data
}

/// CodexAppServerError 描述 app-server 链路的安全错误分类，不携带进程输出或认证信息。
public enum CodexAppServerError: Error, Equatable {
    /// 未找到可执行的 Codex CLI。
    case binaryNotFound
    /// app-server 在完成协议交互前退出或无法启动。
    case unavailable
    /// 当前 Codex 版本不支持所需协议。
    case incompatible
    /// app-server 未在限定时间内返回结果。
    case timedOut
}

/// CodexBinaryLocator 在 GUI 应用常见的有限路径中查找 Codex CLI。
public struct CodexBinaryLocator {
    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileManager: FileManager

    /// CodexBinaryLocator.init 允许注入环境与主目录，同时默认使用当前进程环境。
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    /// CodexBinaryLocator.locate 返回第一个可执行候选；`CODEX_BINARY` 拥有最高优先级。
    public func locate() -> URL? {
        for candidate in candidates() where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private func candidates() -> [URL] {
        var paths: [String] = []
        if let override = environment["CODEX_BINARY"], !override.isEmpty {
            paths.append(override)
        }

        paths.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/bin/codex",
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            homeDirectory.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
            homeDirectory.appendingPathComponent(".volta/bin/codex").path
        ])

        // GUI 应用通常没有用户 shell 的 PATH，因此显式补齐 NVM 各版本目录。
        let nvmVersions = homeDirectory.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            paths.append(contentsOf: versions.sorted { $0.path > $1.path }.map {
                $0.appendingPathComponent("bin/codex").path
            })
        }

        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
            })
        }

        var seen = Set<String>()
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}

/// CodexAppServerClient 通过 JSONL RPC 与 Codex 自带 app-server 交互。
public struct CodexAppServerClient: AppServerUsageFetching {
    private let binaryLocator: CodexBinaryLocator
    private let timeout: Duration

    /// CodexAppServerClient.init 创建客户端，默认将完整握手和读取限制在 10 秒内。
    public init(binaryLocator: CodexBinaryLocator = CodexBinaryLocator(), timeout: Duration = .seconds(10)) {
        self.binaryLocator = binaryLocator
        self.timeout = timeout
    }

    /// CodexAppServerClient.fetch 完成 initialize/initialized 握手后读取账号额度。
    public func fetch() async throws -> Data {
        guard let executableURL = binaryLocator.locate() else {
            throw CodexAppServerError.binaryNotFound
        }

        let session = AppServerProcessSession(executableURL: executableURL)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await session.execute() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexAppServerError.timedOut
            }

            defer {
                group.cancelAll()
                session.cancel()
            }
            guard let result = try await group.next() else {
                throw CodexAppServerError.unavailable
            }
            return result
        }
    }
}

private final class AppServerProcessSession: @unchecked Sendable {
    private let executableURL: URL
    private let queue = DispatchQueue(label: "CodexQuotaWidget.app-server")
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var initialized = false

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func execute() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation: continuation) }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        queue.async {
            self.finish(with: .failure(CancellationError()))
        }
    }

    private func start(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]

        var childEnvironment = ProcessInfo.processInfo.environment
        let binaryDirectory = executableURL.deletingLastPathComponent().path
        let inheritedPath = childEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // npm/NVM 安装的 Codex 使用 `/usr/bin/env node`；GUI 进程的最小 PATH 通常找不到同目录的 node。
        childEnvironment["PATH"] = "\(binaryDirectory):\(inheritedPath)"
        process.environment = childEnvironment

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // stderr 可能包含本地环境细节；小组件不消费也不记录它。
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard self?.continuation != nil else { return }
                self?.finish(with: .failure(CodexAppServerError.unavailable))
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.receive(data) }
        }

        do {
            try process.run()
            try send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "codex-quota-widget", "version": "1.1"],
                    "capabilities": [:]
                ]
            ])
        } catch {
            finish(with: .failure(CodexAppServerError.unavailable))
        }
    }

    private func receive(_ data: Data) {
        guard continuation != nil else { return }
        guard !data.isEmpty else {
            finish(with: .failure(CodexAppServerError.unavailable))
            return
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            handleLine(Data(line))
            if continuation == nil { return }
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue else {
            return
        }

        if object["error"] != nil {
            finish(with: .failure(CodexAppServerError.incompatible))
            return
        }

        if id == 1, object["result"] != nil, !initialized {
            initialized = true
            do {
                // 等待 initialize 成功后再发 initialized 和业务请求，避免依赖进程调度时序。
                try send(["method": "initialized"])
                try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
            } catch {
                finish(with: .failure(CodexAppServerError.unavailable))
            }
            return
        }

        guard id == 2, let result = object["result"] else { return }
        do {
            finish(with: .success(try JSONSerialization.data(withJSONObject: result)))
        } catch {
            finish(with: .failure(CodexAppServerError.incompatible))
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func finish(with result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        outputPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        continuation.resume(with: result)
    }
}
