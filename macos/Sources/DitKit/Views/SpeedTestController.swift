import Foundation
import AppKit
import Observation
import DitKitCore

/// 测速页面的状态机。运行逻辑在 DitKitCore 的 SpeedTestRunner，这里只管交互状态。
@MainActor
@Observable
final class SpeedTestController {
    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case failed(String)
    }

    private static let directoryKey = "DitKitSpeedTestDirectory"

    var phase: Phase = .idle
    var size: SpeedTestSize = .default
    var directoryURL: URL?
    var progress: SpeedTestProgress?
    var result: SpeedTestResult?
    var directoryNote = ""

    @ObservationIgnored private var cancelFlag: CancelFlag?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    init() {
        // 记住上次选择的目标目录；联调时可用启动参数直接注入目录。
        if let injected = Self.injectedDirectory() {
            directoryURL = injected
            directoryNote = "由启动参数指定"
        } else if let saved = UserDefaults.standard.string(forKey: Self.directoryKey),
                  !saved.isEmpty {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.path) {
                directoryURL = url
            }
        }
    }

    /// 仅供联调：直接运行二进制时传 --speedtest-run 自动开始 1 GiB 测速。
    static var shouldAutoStart: Bool {
        ProcessInfo.processInfo.arguments.contains("--speedtest-run")
    }

    private static func injectedDirectory() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--speedtest-dir"), index + 1 < args.count else {
            return nil
        }
        return URL(fileURLWithPath: args[index + 1])
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "测速会在所选目录写入一个临时文件，测试结束后自动删除。"
        if let current = directoryURL { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryURL = url
        directoryNote = ""
        UserDefaults.standard.set(url.path, forKey: Self.directoryKey)
    }

    func start() {
        // 联调参数每次都重新注入，避免被 UserDefaults 里记住的旧目录覆盖。
        if let injected = Self.injectedDirectory() {
            directoryURL = injected
            directoryNote = "由启动参数指定"
        }
        guard !isRunning, let directory = directoryURL else { return }
        let config = SpeedTestConfig(size: size, directoryURL: directory)
        let flag = CancelFlag()
        cancelFlag = flag

        phase = .running
        result = nil
        progress = SpeedTestProgress(stage: .writing, bytesDone: 0, totalBytes: config.bytes)

        task = Task { [weak self] in
            do {
                let value = try await SpeedTestRunner.run(
                    config: config,
                    progress: { item in
                        Task { @MainActor in self?.progress = item }
                    },
                    isCancelled: { flag.isSet }
                )
                self?.result = value
                self?.phase = .finished
            } catch let error as SpeedTestError {
                self?.phase = error == .cancelled ? .cancelled : .failed(error.localizedDescription)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.progress = nil
            self?.cancelFlag = nil
            self?.task = nil
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelFlag?.set()
        phase = .cancelled
    }
}

/// 跨线程取消标志：主线程写、后台 IO 线程读，用锁保护。
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
