import Foundation
import Darwin

/// 顺序读写测速执行器。
///
/// 流程：可用空间预检 → 顺序写固定模式数据块 → F_FULLFSYNC 真正落盘 →
/// 关闭后重新打开并 F_NOCACHE 顺序读回 → 计时 → 无条件删除自己创建的临时文件。
/// 只用顺序 write/read，不做随机 IO；不修改目标目录里的任何既有文件。
public enum SpeedTestRunner {
    public static func run(
        config: SpeedTestConfig,
        progress: @Sendable @escaping (SpeedTestProgress) -> Void,
        isCancelled: @Sendable @escaping () -> Bool
    ) async throws -> SpeedTestResult {
        // 同步阻塞式 IO 放在全局队列，避免占用协作线程池与主线程。
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try perform(config: config, progress: progress, isCancelled: isCancelled)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func perform(
        config: SpeedTestConfig,
        progress: @Sendable (SpeedTestProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws -> SpeedTestResult {
        let fm = FileManager.default
        let directory = config.directoryURL
        let path = directory.path

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SpeedTestError.directoryMissing(path)
        }
        guard fm.isWritableFile(atPath: path) else {
            throw SpeedTestError.directoryNotWritable(path)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fm.attributesOfFileSystem(forPath: path)
        } catch {
            throw SpeedTestError.ioFailed("读取卷容量失败：\(error.localizedDescription)")
        }
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard SpeedTestMath.canRun(available: free, size: config.bytes) else {
            throw SpeedTestError.insufficientSpace(
                available: free,
                required: SpeedTestMath.requiredFreeBytes(for: config.bytes)
            )
        }

        let fileURL = directory.appendingPathComponent("DitKit-SpeedTest-\(UUID().uuidString).tmp")
        let filePath = fileURL.path
        // 无论成功、失败还是取消，都只删除本次自己创建的这个临时文件。
        defer { try? fm.removeItem(at: fileURL) }

        let blockSize = config.blockSize
        let pattern = [UInt8](repeating: 0xA5, count: blockSize)

        // MARK: 顺序写入
        let writeFD = filePath.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard writeFD >= 0 else {
            throw SpeedTestError.ioFailed("创建临时文件失败：\(errnoMessage())")
        }
        var writeFDOpen = true
        defer { if writeFDOpen { close(writeFD) } }
        // 写入端同样绕过页缓存：否则刚写入的数据会驻留内存，
        // 后面「读取」实际是内存拷贝（曾测出 20 GiB/秒 的虚高读数）。
        _ = fcntl(writeFD, F_NOCACHE, 1)
        // F_GLOBAL_NOCACHE 让该文件的所有页都不进入统一缓冲缓存。
        _ = fcntl(writeFD, F_GLOBAL_NOCACHE, 1)

        let writeStart = Date()
        var written: Int64 = 0
        var lastReport = Date()
        while written < config.bytes {
            if isCancelled() { throw SpeedTestError.cancelled }
            let want = Int(min(Int64(blockSize), config.bytes - written))
            let count = pattern.withUnsafeBytes { raw in
                writeWithRetry(writeFD, raw.baseAddress, want)
            }
            guard count > 0 else {
                throw SpeedTestError.ioFailed("顺序写入失败：\(errnoMessage())")
            }
            written += Int64(count)
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.15 || written == config.bytes {
                progress(SpeedTestProgress(stage: .writing, bytesDone: written, totalBytes: config.bytes))
                lastReport = now
            }
        }
        // 含 SSD 写缓存的强制落盘；老设备不支持时回退到 fsync。
        if fcntl(writeFD, F_FULLFSYNC) != 0 && fsync(writeFD) != 0 {
            throw SpeedTestError.ioFailed("落盘同步失败：\(errnoMessage())")
        }
        let writeSeconds = Date().timeIntervalSince(writeStart)
        close(writeFD)
        writeFDOpen = false

        // MARK: 顺序读取（绕过页缓存）
        let readFD = filePath.withCString { open($0, O_RDONLY) }
        guard readFD >= 0 else {
            throw SpeedTestError.ioFailed("打开临时文件失败：\(errnoMessage())")
        }
        var readFDOpen = true
        defer { if readFDOpen { close(readFD) } }
        // F_NOCACHE：本次读取不进入统一缓冲区缓存，尽量测到真实盘速。
        _ = fcntl(readFD, F_NOCACHE, 1)

        var readBuffer = [UInt8](repeating: 0, count: blockSize)
        let readStart = Date()
        var totalRead: Int64 = 0
        lastReport = Date()
        while totalRead < config.bytes {
            if isCancelled() { throw SpeedTestError.cancelled }
            let count = readBuffer.withUnsafeMutableBytes { raw in
                readWithRetry(readFD, raw.baseAddress, blockSize)
            }
            guard count >= 0 else {
                throw SpeedTestError.ioFailed("顺序读取失败：\(errnoMessage())")
            }
            if count == 0 { break }
            totalRead += Int64(count)
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.15 || totalRead == config.bytes {
                progress(SpeedTestProgress(stage: .reading, bytesDone: totalRead, totalBytes: config.bytes))
                lastReport = now
            }
        }
        let readSeconds = Date().timeIntervalSince(readStart)
        close(readFD)
        readFDOpen = false

        guard totalRead == config.bytes else {
            throw SpeedTestError.shortRead(expected: config.bytes, actual: totalRead)
        }

        return SpeedTestResult(
            bytes: config.bytes,
            writeSeconds: writeSeconds,
            readSeconds: readSeconds,
            directory: path
        )
    }

    /// 被信号中断时重试，避免偶发 EINTR 误判断 IO 失败。
    private static func readWithRetry(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        while true {
            let n = read(fd, buffer, count)
            if n < 0, errno == EINTR { continue }
            return n
        }
    }

    private static func writeWithRetry(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        while true {
            let n = write(fd, buffer, count)
            if n < 0, errno == EINTR { continue }
            return n
        }
    }

    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
