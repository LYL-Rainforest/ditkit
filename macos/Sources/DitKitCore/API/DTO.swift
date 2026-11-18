import Foundation

// 后端已经把所有内容翻译成简体中文，这里只做解码，不做二次本地化。

public struct DiskDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let protocolName: String
    public let label: String

    private enum CodingKeys: String, CodingKey {
        case id, name, type, label
        case protocolName = "protocol"
    }
}

public struct HealthResponse: Codable, Sendable {
    public let status: String
    public let version: String
    public let uptimeSeconds: Int
    public let smartctl: String

    private enum CodingKeys: String, CodingKey {
        case status, version, smartctl
        case uptimeSeconds = "uptime_s"
    }
}

public struct DisksResponse: Codable, Sendable {
    public let disks: [DiskDTO]
    public let count: Int
}

public struct RowDTO: Codable, Sendable, Identifiable {
    public var id: String { (key ?? label) + "|" + value }
    /// 后端给出的稳定机器键（如 nvme_temperature / ata_5）；旧版本报告可能没有。
    public let key: String?
    public let label: String
    public let value: String
    /// 同一行的原始数值，避免从中文展示字符串里二次解析。
    public let numeric: Double?
    public let status: String
    public let note: String?
}

public struct SectionDTO: Codable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let rows: [RowDTO]
}

public struct ReportDTO: Codable, Sendable {
    public let device: DiskDTO
    public let overall: String
    public let status: String
    public let summary: String
    public let generatedAt: String
    public let sections: [SectionDTO]
    public let warnings: [String]
    public let messages: [String]
    public let exitCode: Int
    public let exitNotes: [String]

    private enum CodingKeys: String, CodingKey {
        case device, overall, status, summary, sections, warnings, messages
        case generatedAt = "generated_at"
        case exitCode = "exit_code"
        case exitNotes = "exit_notes"
    }
}

public struct ErrorEnvelope: Codable, Sendable {
    public let error: Detail
    public struct Detail: Codable, Sendable {
        public let code: String
        public let message: String
    }
}
