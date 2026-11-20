import Foundation

/// 传输模式。
public enum TransferMode: String, CaseIterable, Sendable, Identifiable {
    case copy = "复制"
    case sync = "同步"
    public var id: String { rawValue }
}

/// 单条传输记录里对文件做的操作。
public enum TransferAction: String, Sendable {
    case copied = "复制"    // 目标缺失，新增复制
    case updated = "更新"   // 目标已存在但内容不同，覆盖
    case skipped = "跳过"   // 目标已存在且一致，无需处理
    case deleted = "删除"   // 同步模式下删除目标多余项
    case partial = "断点"   // 大文件中途停止，部分数据已保留，可续传
    case failed = "失败"
}

/// 单条文件传输记录，对应 PDF/MHL 报告中的一行。
public struct TransferRecord: Identifiable, Sendable {
    public let id = UUID()
    public let action: TransferAction
    public let relativePath: String     // 相对目标根的路径
    public let sourcePath: String
    public let targetPath: String
    public let size: Int64
    public let algorithm: String
    public let sourceHash: String
    public let targetHash: String
    public let verified: Bool           // 复制/更新后源与目标哈希是否一致
    public let note: String

    public init(action: TransferAction, relativePath: String, sourcePath: String, targetPath: String,
                size: Int64, algorithm: String, sourceHash: String, targetHash: String,
                verified: Bool, note: String) {
        self.action = action
        self.relativePath = relativePath
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.size = size
        self.algorithm = algorithm
        self.sourceHash = sourceHash
        self.targetHash = targetHash
        self.verified = verified
        self.note = note
    }
}

/// 进度快照，供 UI 实时刷新。
public struct TransferProgress: Sendable {
    public var filesDone: Int
    public var filesTotal: Int
    public var currentFile: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var phase: String

    public init(filesDone: Int = 0, filesTotal: Int = 0, currentFile: String = "",
                bytesDone: Int64 = 0, bytesTotal: Int64 = 0, phase: String = "") {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.currentFile = currentFile
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.phase = phase
    }
}

/// 一次传输任务的整体结果。
public struct TransferResult: Sendable {
    public var records: [TransferRecord]
    public var reportURLs: [URL]        // 写入的报告路径（每个目标根一组：.mhl + .pdf）
    public var errorMessage: String?
    public var startedAt: Date
    public var finishedAt: Date
    /// 用户点了「停止」：records 只包含已完成的部分，报告为部分报告。
    public var stopped: Bool
    /// 报告（MHL/PDF）写入失败的原因；传输本身可能成功，但报告没落盘必须让用户知道。
    public var reportErrors: [String]

    public init(records: [TransferRecord] = [], reportURLs: [URL] = [],
                errorMessage: String? = nil, startedAt: Date = Date(), finishedAt: Date = Date(),
                stopped: Bool = false, reportErrors: [String] = []) {
        self.records = records
        self.reportURLs = reportURLs
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stopped = stopped
        self.reportErrors = reportErrors
    }

    public var copied:  Int { records.filter { $0.action == .copied }.count }
    public var updated: Int { records.filter { $0.action == .updated }.count }
    public var skipped: Int { records.filter { $0.action == .skipped }.count }
    public var deleted: Int { records.filter { $0.action == .deleted }.count }
    public var partial: Int { records.filter { $0.action == .partial }.count }
    public var failed:  Int { records.filter { $0.action == .failed }.count }
    public var verifiedOK: Int { records.filter { $0.verified && $0.action != .deleted }.count }
}

/// 单个目标目录的空间估算结果。
public struct TransferSpaceTarget: Sendable, Equatable {
    public let path: String
    public let requiredBytes: Int64
    /// 目标卷可用字节；无法读取时为 -1，此时不做缺口判断。
    public let freeBytes: Int64

    public var shortfall: Int64 {
        guard freeBytes >= 0 else { return 0 }
        return max(0, requiredBytes - freeBytes)
    }
}

/// 一次任务在所有目标目录上的空间估算。
public struct TransferSpaceEstimate: Sendable, Equatable {
    public let targets: [TransferSpaceTarget]

    public var hasShortfall: Bool { targets.contains { $0.shortfall > 0 } }

    /// 供确认弹窗逐行显示缺口。
    public var shortfallLines: [String] {
        targets.filter { $0.shortfall > 0 }.map { target in
            "\(target.path)：还差 \(IOFormat.capacity(target.shortfall))"
        }
    }
}

/// 传输任务配置。
public struct TransferConfig: Sendable {
    public let mode: TransferMode
    public let algorithm: HashAlgorithm
    public let sources: [URL]           // 复制模式：文件/文件夹；同步模式：单个目录
    public let targets: [URL]           // 至少一个目录；复制模式最多三个
    public let reportPlacement: ReportPlacement  // 报告存放位置

    public init(mode: TransferMode, algorithm: HashAlgorithm, sources: [URL], targets: [URL],
                reportPlacement: ReportPlacement = .default) {
        self.mode = mode
        self.algorithm = algorithm
        self.sources = sources
        self.targets = targets
        self.reportPlacement = reportPlacement
    }
}
