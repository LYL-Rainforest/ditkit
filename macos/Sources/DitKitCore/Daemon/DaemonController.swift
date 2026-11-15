import Foundation

/// 随 App 分发的 ditkitd 子进程生命周期管理。
///
/// 正式安装包里 ditkitd 位于 DitKit.app/Contents/MacOS/ditkitd，App 启动时自动拉起、
/// 退出时发 SIGTERM 让它自行删除 runtime.json。开发态直接运行 SwiftPM 二进制时没有内嵌后端，
/// 此时保持原有行为：连接机器上已手动启动的 ditkitd，方便调试。
@MainActor
public final class DaemonController {
    public static let shared = DaemonController()

    private var process: Process?
    private var ensureTask: Task<Void, Error>?

    private init() {}

    /// 内嵌后端路径，仅当文件确实可执行时才认为处于「安装包模式」。
    private var bundledDaemonURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ditkitd", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private var dataDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DitKit", isDirectory: true)
    }

    /// 保证有一个可用后端：已有存活的 ditkitd 就复用，否则启动内嵌的那份。
    /// 多次调用（例如反复点「重新连接并刷新」）会合并为同一次启动，避免开出多个守护进程。
    public func ensureRunning() async throws {
        if let ensureTask {
            return try await ensureTask.value
        }
        let task = Task { try await self.startIfNeeded() }
        ensureTask = task
        do {
            try await task.value
        } catch {
            ensureTask = nil
            throw error
        }
    }

    /// App 退出时调用；只终止由本进程亲自拉起的 ditkitd，不影响用户手动启动的实例。
    public func stop() {
        guard let process, process.isRunning else { return }
        process.terminate() // SIGTERM：Go 侧 signal.NotifyContext 会清理 runtime.json 后退出
        self.process = nil
    }

    private func startIfNeeded() async throws {
        if await runtimeIsAlive() { return }
        guard let executable = bundledDaemonURL else {
            // 开发态：没有内嵌后端，交给 AppState 走原来的连接/报错流程。
            return
        }
        // 残留的 runtime.json 会让 AppState 读到一个已死端口，先清掉。
        try? FileManager.default.removeItem(at: RuntimeStore.defaultURL())

        let daemon = Process()
        daemon.executableURL = executable
        daemon.arguments = ["-port", "0"]
        daemon.environment = daemonEnvironment()
        let logHandle = makeLogHandle()
        daemon.standardOutput = logHandle
        daemon.standardError = logHandle
        do {
            try daemon.run()
        } catch {
            throw DaemonError.launchFailed(error.localizedDescription)
        }
        process = daemon

        // Serve() 会先 Listen 再写 runtime.json，因此文件一出现端口就已可用。
        for _ in 0..<60 {
            if (try? RuntimeStore.load()) != nil { return }
            if !daemon.isRunning {
                throw DaemonError.exitedEarly(logTail())
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DaemonError.timeout
    }

    /// 用 runtime.json 里的 token 做一次 health 探活，确认端口仍然属于一个活着的后端。
    private func runtimeIsAlive() async -> Bool {
        guard let runtime = try? RuntimeStore.load() else { return false }
        guard let url = URL(string: "http://127.0.0.1:\(runtime.port)/api/v1/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(runtime.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:] // 绕开系统级代理，与 APIClient 保持一致
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// GUI 启动的进程默认 PATH 不含 Homebrew，会导致 ditkitd 找不到 smartctl。
    private func daemonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let known = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        env["PATH"] = (known + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    private func makeLogHandle() -> FileHandle? {
        let dir = dataDirURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: log)
    }

    private func logTail() -> String {
        let log = dataDirURL.appendingPathComponent("daemon.log")
        guard let data = try? Data(contentsOf: log),
              let text = String(data: data.suffix(4096), encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DaemonError: LocalizedError {
    case launchFailed(String)
    case exitedEarly(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "无法启动 ditkitd：\(detail)"
        case .exitedEarly(let log):
            return log.isEmpty ? "ditkitd 启动后立即退出，请确认已安装 smartmontools" : "ditkitd 启动失败：\(log)"
        case .timeout:
            return "ditkitd 启动超时，请查看 ~/Library/Application Support/DitKit/daemon.log"
        }
    }
}
