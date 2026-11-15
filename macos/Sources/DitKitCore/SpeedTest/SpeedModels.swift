import Foundation

// MARK: - 测试规格

/// 可选的测试大小，按二进制计算：1 GiB = 1,073,741,824 字节（1024³）。
/// 界面单位统一写 GiB / MiB/秒，避免「GB 按 1024 算」的歧义。
public enum SpeedTestSize: Int, CaseIterable, Identifiable, Sendable {
    case oneGiB = 1
    case tenGiB = 10
    case hundredGiB = 100

    public static let bytesPerGiB: Int64 = 1_073_741_824

    public var id: Int { rawValue }

    public var bytes: Int64 { Int64(rawValue) * Self.bytesPerGiB }

    public var label: String { "\(rawValue) GiB" }

    public var note: String {
        switch self {
        case .oneGiB: return "最快、临时占用最小"
        case .tenGiB: return "中等规模，约十几秒到一分钟"
        case .hundredGiB: return "最接近持续写入表现，耗时数分钟"
        }
    }

    public static let `default`: SpeedTestSize = .oneGiB
}

public struct SpeedTestConfig: Sendable, Equatable {
    public var bytes: Int64
    public var directoryURL: URL
    public var blockSize: Int

    public init(bytes: Int64, directoryURL: URL, blockSize: Int = 4 * 1024 * 1024) {
        self.bytes = bytes
        self.directoryURL = directoryURL
        self.blockSize = max(64 * 1024, blockSize)
    }

    public init(size: SpeedTestSize, directoryURL: URL) {
        self.init(bytes: size.bytes, directoryURL: directoryURL)
    }
}

/// 顺序读写分两个阶段，各占进度的一半。
public enum SpeedTestStage: String, Sendable {
    case writing
    case reading
}

public struct SpeedTestProgress: Sendable, Equatable {
    public let stage: SpeedTestStage
    public let bytesDone: Int64
    public let totalBytes: Int64

    public init(stage: SpeedTestStage, bytesDone: Int64, totalBytes: Int64) {
        self.stage = stage
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        let half = min(1, max(0, Double(bytesDone) / Double(totalBytes))) * 0.5
        return stage == .writing ? half : 0.5 + half
    }

    public var stageText: String {
        stage == .writing ? "正在顺序写入…" : "正在顺序读取（绕过缓存）…"
    }

    public var detailText: String {
        "\(SpeedFormat.size(bytesDone)) / \(SpeedFormat.size(totalBytes))"
    }
}

public struct SpeedTestResult: Sendable, Equatable {
    public let bytes: Int64
    public let writeSeconds: Double
    public let readSeconds: Double
    public let directory: String
    public let finishedAt: Date

    public init(bytes: Int64, writeSeconds: Double, readSeconds: Double,
                directory: String, finishedAt: Date = Date()) {
        self.bytes = bytes
        self.writeSeconds = writeSeconds
        self.readSeconds = readSeconds
        self.directory = directory
        self.finishedAt = finishedAt
    }

    public var writeBytesPerSecond: Double {
        SpeedTestMath.bytesPerSecond(bytes, seconds: writeSeconds)
    }

    public var readBytesPerSecond: Double {
        SpeedTestMath.bytesPerSecond(bytes, seconds: readSeconds)
    }
}

// MARK: - 二进制单位格式化

public enum SpeedFormat {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB"]

    public static func size(_ bytes: Int64) -> String {
        format(Double(bytes))
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 MiB/秒" }
        return format(bytesPerSecond) + "/秒"
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        var v = value
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return String(format: "%.0f B", v) }
        let text = abs(v - v.rounded()) < 0.05
            ? String(format: "%.0f", v)
            : String(format: "%.1f", v)
        return text + " " + units[i]
    }
}

// MARK: - 纯计算（可单测，不触碰磁盘）

public enum SpeedTestMath {
    /// 除测试数据本身外，额外预留 1 GiB，避免把磁盘写满。
    public static let safetyMarginBytes: Int64 = 1_073_741_824

    public static func requiredFreeBytes(for size: Int64) -> Int64 {
        size + safetyMarginBytes
    }

    public static func canRun(available: Int64, size: Int64) -> Bool {
        available >= requiredFreeBytes(for: size)
    }

    public static func bytesPerSecond(_ bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0, seconds.isFinite else { return 0 }
        return Double(bytes) / seconds
    }

    /// 分块数量，最后一块可以不足 blockSize。
    public static func blockCount(total: Int64, blockSize: Int) -> Int {
        guard total > 0, blockSize > 0 else { return 0 }
        return Int((total + Int64(blockSize) - 1) / Int64(blockSize))
    }
}

// MARK: - 错误（中文提示）

public enum SpeedTestError: Error, LocalizedError, Equatable {
    case directoryMissing(String)
    case directoryNotWritable(String)
    case insufficientSpace(available: Int64, required: Int64)
    case ioFailed(String)
    case shortRead(expected: Int64, actual: Int64)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .directoryMissing(let path):
            return "目标目录不存在：\(path)"
        case .directoryNotWritable(let path):
            return "目标目录不可写：\(path)"
        case .insufficientSpace(let available, let required):
            return "磁盘可用空间不足：可用 \(SpeedFormat.size(available))，需要至少 \(SpeedFormat.size(required))（含 1 GiB 安全余量）"
        case .ioFailed(let detail):
            return "磁盘读写失败：\(detail)"
        case .shortRead(let expected, let actual):
            return "读取数据量不完整：应为 \(SpeedFormat.size(expected))，实际 \(SpeedFormat.size(actual))"
        case .cancelled:
            return "测速已取消，临时文件已清理"
        }
    }
}
