import Foundation
import Darwin

/// 文件复制器。
///
/// 复制策略（与测速一致）：
/// - **< 4 MiB**：走系统页缓存，直接用 `FileManager.copyItem`（小文件缓存收益高）。
/// - **≥ 4 MiB**：绕过页缓存直传存储硬件（`F_NOCACHE` + `F_GLOBAL_NOCACHE`），
///   单次读写块 4 MiB，单个缓冲复用，避免大文件污染内存、并测到真实盘速。
///
/// 大文件在复制过程中顺带算出「源哈希」，避免为校验而二次读盘。
public enum FileCopier {
    public static let smallThreshold: Int64 = 4 * 1024 * 1024
    public static let blockSize = 4 * 1024 * 1024

    /// 复制 `src` → `dst`，并返回源文件哈希。
    /// 调用方需确保 `dst` 的父目录已存在。
    public static func copyAndHashSource(
        _ src: URL,
        to dst: URL,
        algorithm: HashAlgorithm
    ) async throws -> (size: Int64, sourceHash: String) {
        let size = fileSize(src)
        if size >= 0, size < smallThreshold {
            let sourceHash = try await FileHasher.hash(fileAt: src, algorithm: algorithm).value
            try copySmall(src, to: dst)
            return (size, sourceHash)
        }
        return try await copyLargeDirect(src, to: dst, algorithm: algorithm)
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
    /// 同时把每个读取块喂给增量哈希器算出源哈希。
    private static func copyLargeDirect(
        _ src: URL,
        to dst: URL,
        algorithm: HashAlgorithm
    ) async throws -> (Int64, String) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int64, String), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try performLargeDirect(src, to: dst, algorithm: algorithm)
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
        algorithm: HashAlgorithm
    ) throws -> (Int64, String) {
        let srcFD = src.path.withCString { open($0, O_RDONLY) }
        guard srcFD >= 0 else { throw CopyError.openSource(errnoMessage()) }
        var srcOpen = true
        defer { if srcOpen { close(srcFD) } }
        // 读取端绕过页缓存：刚读出的数据不驻留统一缓冲缓存。
        _ = fcntl(srcFD, F_NOCACHE, 1)

        let dstFD = dst.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644)) }
        guard dstFD >= 0 else { throw CopyError.openDest(errnoMessage()) }
        var dstOpen = true
        defer { if dstOpen { close(dstFD) } }
        // 写入端绕过页缓存（含全局），否则刚写入的数据驻留内存，
        // 后续「读回校验」会变成内存拷贝，掩盖真实盘速与潜在写入错误。
        _ = fcntl(dstFD, F_NOCACHE, 1)
        _ = fcntl(dstFD, F_GLOBAL_NOCACHE, 1)

        let hasher = try IncrementalHasher(algorithm: algorithm)
        // 单一缓冲复用：整次复制只分配/释放一次。
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 4096)
        defer { buffer.deallocate() }

        var total: Int64 = 0
        while true {
            let n = read(srcFD, buffer, blockSize)
            if n < 0 { throw CopyError.read(errnoMessage()) }
            if n == 0 { break }
            var offset = 0
            while offset < n {
                let w = write(dstFD, buffer.advanced(by: offset), n - offset)
                if w < 0 { throw CopyError.write(errnoMessage()) }
                offset += w
            }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: n))
            total += Int64(n)
        }
        let sourceHash = hasher.finalize()
        // 强制落盘（含 SSD 写缓存），失败回退到 fsync。
        if fcntl(dstFD, F_FULLFSYNC) != 0 { _ = fsync(dstFD) }
        close(dstFD); dstOpen = false
        close(srcFD); srcOpen = false
        return (total, sourceHash)
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

    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
