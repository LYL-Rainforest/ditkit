import Foundation
import CommonCrypto
import Darwin
import xxhash

/// 校验算法。默认 xxHash128（更快、128 位）；MD5 作为可选兼容项。
public enum HashAlgorithm: String, CaseIterable, Sendable, Identifiable {
    case xxHash128 = "xxHash128"
    case md5 = "MD5"

    public var id: String { rawValue }
    public var label: String { rawValue }

    /// 哈希文件名后缀，便于在报告里区分。
    public var tag: String {
        switch self {
        case .xxHash128: return "xxh128"
        case .md5: return "md5"
        }
    }

    /// 由 MHL 的哈希元素名反查算法；不支持的算法返回 nil。
    public init?(mhlTag: String) {
        switch mhlTag.lowercased() {
        case "xxh128": self = .xxHash128
        case "md5": self = .md5
        default: return nil
        }
    }
}

/// 增量哈希器：支持边读边算，供大文件直传复制时复用同一份读取。
public final class IncrementalHasher {
    public let algorithm: HashAlgorithm
    private var md5ctx: CC_MD5_CTX
    private var xxhState: UnsafeMutableRawPointer?

    public init(algorithm: HashAlgorithm) throws {
        self.algorithm = algorithm
        self.md5ctx = CC_MD5_CTX()
        CC_MD5_Init(&md5ctx)
        if algorithm == .xxHash128 {
            guard let s = DitKit_xxh128_create() else { throw HashError.cannotCreateState }
            DitKit_xxh128_reset(s)
            xxhState = s
        }
    }

    public func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public func update(_ buffer: UnsafeRawBufferPointer) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        switch algorithm {
        case .md5:
            CC_MD5_Update(&md5ctx, base, CC_LONG(buffer.count))
        case .xxHash128:
            _ = DitKit_xxh128_update(xxhState, base, buffer.count)
        }
    }

    public func finalize() -> String {
        switch algorithm {
        case .md5:
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            CC_MD5_Final(&digest, &md5ctx)
            return digest.map { String(format: "%02x", $0) }.joined()
        case .xxHash128:
            var low: UInt64 = 0, high: UInt64 = 0
            DitKit_xxh128_digest(xxhState, &low, &high)
            return String(format: "%016llx%016llx", high, low)
        }
    }

    deinit {
        if let s = xxhState { DitKit_xxh128_free(s) }
    }

    private enum HashError: Error { case cannotCreateState }
}

/// 文件哈希器：缓存式整文件哈希，用于复制后校验目标、或复制前哈希小文件。
public enum FileHasher {
    public static func hash(
        fileAt url: URL,
        algorithm: HashAlgorithm,
        chunkSize: Int = 1 << 20
    ) async throws -> (value: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let hasher = try IncrementalHasher(algorithm: algorithm)
        var total: Int64 = 0
        while true {
            let data = try handle.read(upToCount: chunkSize)
            guard let data, !data.isEmpty else { break }
            hasher.update(data)
            total += Int64(data.count)
            if total % (Int64(chunkSize) * 16) == 0 { await Task.yield() }
        }
        return (hasher.finalize(), total)
    }
}
