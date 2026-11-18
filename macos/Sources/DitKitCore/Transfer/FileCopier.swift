import Foundation
import Darwin
import CommonCrypto

/// 断点续传所需的状态（写在目标目录的隐藏 `.ditkit-partial` 子目录里）。
public struct CopyResumeState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public let sourcePath: String
    public let sourceSize: Int64
    public let sourceMTime: Double
    public let algorithm: String
    public let copiedBytes: Int64
}

/// 一次复制的结果。`completed == false` 表示中途停止，部分数据已保留，可再次调用续传。
public struct CopyOutcome: Sendable {
    public let size: Int64
    public let sourceHash: String
    public let completed: Bool
    public let resumed: Bool
    public let partialBytes: Int64

    public init(size: Int64, sourceHash: String, completed: Bool,
                resumed: Bool, partialBytes: Int64) {
        self.size = size
        self.sourceHash = sourceHash
        self.completed = completed
        self.resumed = resumed
        self.partialBytes = partialBytes
    }
}

public enum FileCopier {
    public static let smallThreshold: Int64 = 4 * 1024 * 1024
    public static let blockSize = 4 * 1024 * 1024
    public static let partialDirectoryName = ".ditkit-partial"

    /// 每次写入一个 4 MiB 数据块后回调（后台线程），供测试/进度显示观察中断点。
    public typealias ByteProgress = @Sendable (Int64) -> Void

    /// 复制 `src` → `dst`，并返回源文件哈希。
    /// 调用方需确保 `dst` 的父目录已存在。
    /// - parameter knownSourceHash: 若调用方已经算过源文件哈希（例如同大小比对时），
    ///   传入可避免复制过程中再次哈希源文件——大文件因此少一次全量读盘。
    public static func copyAndHashSource(
        _ src: URL,
        to dst: URL,
        algorithm: HashAlgorithm,
        knownSourceHash: String? = nil
    ) async throws -> (size: Int64, sourceHash: String) {
        let outcome = try await copyAndHashSourceWithResume(
            src, to: dst, algorithm: algorithm, knownSourceHash: knownSourceHash
        )
        return (outcome.size, outcome.sourceHash)
    }

    /// 带断点续传的复制入口。仅 ≥4 MiB 的大文件使用部分文件；小文件仍一次性复制。
    public static func copyAndHashSourceWithResume(
        _ src: URL,
        to dst: URL,
        algorithm: HashAlgorithm,
        knownSourceHash: String? = nil,
        control: RunControl? = nil,
        onBlock: ByteProgress? = nil
    ) async throws -> CopyOutcome {
        let size = fileSize(src)
        if size >= 0, size < smallThreshold {
            let sourceHash = try await FileHasher.hash(fileAt: src, algorithm: algorithm).value
            try copySmall(src, to: dst)
            return CopyOutcome(size: size, sourceHash: sourceHash, completed: true,
                               resumed: false, partialBytes: size)
        }
        return try await copyLargeDirect(src, to: dst, algorithm: algorithm,
                                         knownSourceHash: knownSourceHash,
                                         control: control, onBlock: onBlock)
    }

    // MARK: - 小文件：系统缓存路径

    private static func copySmall(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    // MARK: - 大文件：绕过缓存直传

    /// 在后台全局队列执行阻塞式直传，避免占用协作线程池；4 MiB 块、缓冲复用，
    /// 同时把每个读取块喂给增量哈希器算出源哈希。块边界支持暂停/停止并保存断点。
    private static func copyLargeDirect(
        _ src: URL,
        to dst: URL,
        algorithm: HashAlgorithm,
        knownSourceHash: String?,
        control: RunControl?,
        onBlock: ByteProgress?
    ) async throws -> CopyOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CopyOutcome, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try performLargeDirect(src, to: dst, algorithm: algorithm,
                                                        knownSourceHash: knownSourceHash,
                                                        control: control, onBlock: onBlock)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performLargeDirect(
        _ src: URL,
        to dst: URL,
        algorithm: HashAlgorithm,
        knownSourceHash: String?,
        control: RunControl?,
        onBlock: ByteProgress?
    ) throws -> CopyOutcome {
        let fm = FileManager.default
        let sourceSize = fileSize(src)
        guard sourceSize >= 0 else { throw CopyError.openSource("无法读取源文件大小") }
        let sourceMTime = (try? src.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0

        let root = dst.deletingLastPathComponent().appendingPathComponent(partialDirectoryName)
        let key = stableKey(dst.path)
        let stateURL = root.appendingPathComponent(key + ".json")
        let partURL = root.appendingPathComponent(key + ".part")
        let resume = validResumeState(
            at: stateURL, part: partURL, source: src, sourceSize: sourceSize,
            sourceMTime: sourceMTime, algorithm: algorithm
        )
        let startOffset = resume?.copiedBytes ?? 0
        if resume == nil {
            try? fm.removeItem(at: stateURL)
            try? fm.removeItem(at: partURL)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let srcFD = src.path.withCString { open($0, O_RDONLY) }
        guard srcFD >= 0 else { throw CopyError.openSource(errnoMessage()) }
        var srcOpen = true
        defer { if srcOpen { close(srcFD) } }
        // 读取端绕过页缓存：刚读出的数据不驻留统一缓冲缓存。
        _ = fcntl(srcFD, F_NOCACHE, 1)

        // 部分文件与目标同目录（同一卷），完成后可直接 rename 原子替换。
        let partFD = partURL.path.withCString {
            open($0, O_WRONLY | O_CREAT, mode_t(0o644))
        }
        guard partFD >= 0 else { throw CopyError.openDest(errnoMessage()) }
        var partOpen = true
        defer { if partOpen { close(partFD) } }
        _ = fcntl(partFD, F_NOCACHE, 1)
        _ = fcntl(partFD, F_GLOBAL_NOCACHE, 1)
        if resume == nil { _ = ftruncate(partFD, 0) }
        if startOffset > 0 { _ = lseek(partFD, off_t(startOffset), SEEK_SET) }

        // 已知源哈希时不再创建增量哈希器；续传仍会从头读一遍源以生成完整哈希。
        let hasher = knownSourceHash == nil ? try? IncrementalHasher(algorithm: algorithm) : nil
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 4096)
        defer { buffer.deallocate() }

        var totalRead: Int64 = 0
        var written = startOffset
        var interrupted = false
        while true {
            // 暂停/停止在块边界生效：暂停时阻塞当前后台线程短轮询，停止则保留已写部分。
            if let control {
                while control.isPaused && !control.isStopped { usleep(50_000) }
                if control.isStopped { interrupted = true; break }
            }
            let n = readWithRetry(srcFD, buffer, blockSize)
            if n < 0 { throw CopyError.read(errnoMessage()) }
            if n == 0 { break }

            let skip = max(0, startOffset - totalRead)
            if skip < Int64(n) {
                let writeStart = Int(skip)
                var offset = writeStart
                while offset < n {
                    let w = writeWithRetry(partFD, buffer.advanced(by: offset), n - offset)
                    if w < 0 { throw CopyError.write(errnoMessage()) }
                    if w == 0 { throw CopyError.write("写入返回 0 字节，已中止以避免死循环") }
                    offset += w
                }
                written += Int64(n - writeStart)
            }
            hasher?.update(UnsafeRawBufferPointer(start: buffer, count: n))
            totalRead += Int64(n)
            onBlock?(written)
        }

        // 强制落盘（含 SSD 写缓存），失败回退到 fsync；中断时也必须确认部分数据已持久化。
        if fcntl(partFD, F_FULLFSYNC) != 0 { _ = fsync(partFD) }

        if interrupted {
            let state = CopyResumeState(
                sourcePath: src.standardizedFileURL.path,
                sourceSize: sourceSize, sourceMTime: sourceMTime,
                algorithm: algorithm.tag, copiedBytes: written
            )
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: stateURL, options: .atomic)
            }
            close(partFD); partOpen = false
            close(srcFD); srcOpen = false
            return CopyOutcome(size: sourceSize, sourceHash: "", completed: false,
                               resumed: resume != nil, partialBytes: written)
        }

        guard written == sourceSize else {
            throw CopyError.write("源文件大小在传输中发生变化，已放弃替换目标")
        }
        close(partFD); partOpen = false
        close(srcFD); srcOpen = false

        // 部分文件与目标在同一目录，rename 是原子的：要么看到完整目标，要么仍是部分文件。
        try? fm.removeItem(at: dst)
        if rename(partURL.path, dst.path) != 0 { throw CopyError.write(errnoMessage()) }
        try? fm.removeItem(at: stateURL)
        cleanupPartialRootIfEmpty(root)

        let sourceHash = knownSourceHash ?? hasher?.finalize() ?? ""
        return CopyOutcome(size: sourceSize, sourceHash: sourceHash,
                           completed: true, resumed: resume != nil, partialBytes: written)
    }

    /// 是否存在可续传的部分文件；调用方可据此在报告里标注「从断点续传」。
    public static func hasResumableCopy(
        source: URL, destination: URL, algorithm: HashAlgorithm
    ) -> Bool {
        let root = destination.deletingLastPathComponent().appendingPathComponent(partialDirectoryName)
        let key = stableKey(destination.path)
        let sourceSize = fileSize(source)
        let sourceMTime = (try? source.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        return validResumeState(
            at: root.appendingPathComponent(key + ".json"),
            part: root.appendingPathComponent(key + ".part"),
            source: source, sourceSize: sourceSize,
            sourceMTime: sourceMTime, algorithm: algorithm
        ) != nil
    }

    /// 丢弃某个目标的断点（例如目标文件已被替换或同步重建时）。
    public static func clearResume(for destination: URL) {
        let root = destination.deletingLastPathComponent().appendingPathComponent(partialDirectoryName)
        let key = stableKey(destination.path)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key + ".json"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key + ".part"))
        cleanupPartialRootIfEmpty(root)
    }

    private static func validResumeState(
        at stateURL: URL,
        part: URL,
        source: URL,
        sourceSize: Int64,
        sourceMTime: Double,
        algorithm: HashAlgorithm
    ) -> CopyResumeState? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(CopyResumeState.self, from: data),
              state.version == 1,
              state.sourceSize == sourceSize,
              abs(state.sourceMTime - sourceMTime) < 0.001,
              state.algorithm == algorithm.tag,
              state.copiedBytes > 0, state.copiedBytes <= sourceSize,
              fileSize(part) == state.copiedBytes else { return nil }
        let saved = URL(fileURLWithPath: state.sourcePath).standardizedFileURL.path
        let current = source.standardizedFileURL.path
        guard saved == current || saved == source.path else { return nil }
        return state
    }

    private static func cleanupPartialRootIfEmpty(_ root: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              names.isEmpty else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// 目标路径的稳定短键：用 SHA-256 前 16 字节，避免相对路径中的特殊字符落到文件名里。
    private static func stableKey(_ path: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        Array(path.utf8).withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(raw.count), &digest)
        }
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 工具

    public static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private enum CopyError: Error {
        case openSource(String), openDest(String), read(String), write(String)
    }

    /// 被信号中断（EINTR）时重试 read，其它错误原样返回 -1。
    private static func readWithRetry(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        while true {
            let n = read(fd, buffer, count)
            if n < 0, errno == EINTR { continue }
            return n
        }
    }

    /// 被信号中断时重试 write，其它错误原样返回 -1。
    private static func writeWithRetry(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
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
