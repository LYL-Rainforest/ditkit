import Foundation

/// 长任务（文件传输 / EXIF 扫描 / 重命名 / MHL 批量校验）的执行控制器。
///
/// 设计约定：
/// - 在文件边界检查控制状态；≥4 MiB 的大文件复制额外在 4 MiB 块边界检查，
///   停止时保留部分数据作为断点，小文件仍保证完整处理不留半截文件；
/// - 暂停用异步短轮询等待，不阻塞 Swift 并发协作线程池；
/// - 停止是终态，不可恢复；`gate()` 返回 `false` 后调用方立即收尾并写部分报告；
/// - 线程安全，可以在 `@MainActor` 的界面层与非隔离的引擎层之间直接共享。
public final class RunControl: @unchecked Sendable {
    public enum State: String, Sendable {
        case running
        case paused
        case stopped
    }

    private let lock = NSLock()
    private var state: State = .running

    public init() {}

    /// 当前状态的线程安全快照。
    public func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var isPaused: Bool { snapshot() == .paused }
    public var isStopped: Bool { snapshot() == .stopped }

    /// 暂停。若已停止则保持停止（不可逆）。
    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        if state == .running { state = .paused }
    }

    /// 从暂停恢复。若已停止则保持停止（不可逆）。
    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        if state == .paused { state = .running }
    }

    /// 停止。同时唤醒处于暂停等待中的文件边界检查。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        state = .stopped
    }

    /// 在每个文件（或每条清单记录）处理前调用：
    /// - `running` → `true`，继续处理；
    /// - `paused` → 异步等待，直到恢复或停止；
    /// - `stopped` / 所在 Task 被取消 → `false`，调用方应停止遍历并生成部分报告。
    public func gate() async -> Bool {
        while true {
            if Task.isCancelled { return false }
            switch snapshot() {
            case .running:
                return true
            case .stopped:
                return false
            case .paused:
                // 50ms 轮询：暂停期间几乎不占 CPU，也不会占住协作线程。
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}
