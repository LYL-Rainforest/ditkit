import Foundation

/// 一个被追踪的 SMART 指标定义：机器键、展示名、单位与告警阈值。
public enum SMARTMetricDefinition: String, CaseIterable, Sendable {
    case temperature
    case availableSpare
    case percentageUsed
    case mediaErrors
    case errorLogEntries
    case powerOnHours
    case reallocated
    case pending
    case uncorrectable

    /// 后端 Row.key；同时用展示标签做旧报告的兼容匹配。
    public var key: String {
        switch self {
        case .temperature: return "nvme_temperature"
        case .availableSpare: return "nvme_available_spare"
        case .percentageUsed: return "nvme_percentage_used"
        case .mediaErrors: return "nvme_media_errors"
        case .errorLogEntries: return "nvme_num_err_log_entries"
        case .powerOnHours: return "nvme_power_on_hours"
        case .reallocated: return "ata_5"
        case .pending: return "ata_197"
        case .uncorrectable: return "ata_198"
        }
    }

    public var label: String {
        switch self {
        case .temperature: return "温度"
        case .availableSpare: return "可用备用空间"
        case .percentageUsed: return "寿命消耗"
        case .mediaErrors: return "介质错误"
        case .errorLogEntries: return "错误日志条目"
        case .powerOnHours: return "通电时间"
        case .reallocated: return "重映射扇区数"
        case .pending: return "待映射扇区数"
        case .uncorrectable: return "无法校正扇区数"
        }
    }

    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .availableSpare, .percentageUsed: return "%"
        case .powerOnHours: return "小时"
        default: return "次"
        }
    }

    public var aliases: [String] {
        switch self {
        case .temperature: return ["温度", "当前温度"]
        case .availableSpare: return ["可用备用空间"]
        case .percentageUsed: return ["寿命消耗", "已用寿命百分比"]
        case .mediaErrors: return ["介质错误"]
        case .errorLogEntries: return ["错误日志条目数", "错误日志"]
        case .powerOnHours: return ["累计通电时间", "通电时间"]
        case .reallocated: return ["重映射扇区数", "重映射扇区计数"]
        case .pending: return ["待映射扇区数"]
        case .uncorrectable: return ["无法校正扇区数", "离线无法校正扇区数"]
        }
    }

    /// nil 表示只记录趋势、不参与阈值告警。
    public func level(for value: Double) -> SMARTAlert.Level? {
        switch self {
        case .temperature:
            return value >= 55 ? .critical : (value >= 45 ? .warn : nil)
        case .availableSpare:
            return value <= 10 ? .critical : (value <= 20 ? .warn : nil)
        case .percentageUsed:
            return value >= 95 ? .critical : (value >= 80 ? .warn : nil)
        case .mediaErrors:
            return value > 0 ? .critical : nil
        case .errorLogEntries:
            return value > 0 ? .warn : nil
        case .reallocated, .pending, .uncorrectable:
            return value >= 10 ? .critical : (value > 0 ? .warn : nil)
        case .powerOnHours:
            return nil
        }
    }
}

/// 某次 SMART 报告里的一个指标值。
public struct SMARTMetricValue: Codable, Sendable, Equatable {
    public let key: String
    public let label: String
    public let value: Double
    public let unit: String
}

/// 一次 SMART 采样的可持久化摘要（只存趋势需要的字段，不存整份报告）。
public struct SMARTSnapshot: Codable, Sendable, Equatable {
    public let date: Date
    public let diskID: String
    public let diskLabel: String
    public let status: String
    public let metrics: [SMARTMetricValue]

    public func metric(_ key: String) -> SMARTMetricValue? {
        metrics.first { $0.key == key }
    }
}

/// 一条阈值告警。
public struct SMARTAlert: Sendable, Equatable, Identifiable {
    public enum Level: String, Sendable { case warn, critical }

    public let key: String
    public let title: String
    public let detail: String
    public let level: Level
    public let value: Double

    public var id: String { "\(key)-\(level.rawValue)" }
}

/// 趋势曲线上的一个点。
public struct SMARTSeriesPoint: Sendable, Equatable {
    public let date: Date
    public let value: Double
}

// MARK: - 持久化（JSONL，按时间顺序追加）

/// SMART 历史存储：每行一个 `SMARTSnapshot`，按稳定磁盘 ID 区分。
/// 用文件而非数据库，便于用户直接查看/备份；异常行会被跳过，不影响其它记录。
public enum SMARTHistory {
    private static let lock = NSLock()
    private static let maxSnapshots = 2_000
    private static let minimumInterval: TimeInterval = 60

    /// - parameter base: 测试时可传入临时目录；默认使用 ~/Library/Application Support/DitKit。
    public static func fileURL(base: URL? = nil) -> URL {
        let root = base ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("smart-history.jsonl")
    }

    /// 从一份完整报告抽取指标并追加历史；同一块盘 60 秒内的重复刷新不会重复写。
    @discardableResult
    public static func record(
        _ report: ReportDTO,
        at date: Date = Date(),
        base: URL? = nil
    ) -> Bool {
        let snapshot = makeSnapshot(from: report, at: date)
        guard !snapshot.metrics.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(base: base)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = readSnapshots(at: url)
        if let last = existing.last, last.diskID == snapshot.diskID,
           date.timeIntervalSince(last.date) < minimumInterval {
            return false
        }
        var all = existing
        all.append(snapshot)
        if all.count > maxSnapshots { all = Array(all.suffix(maxSnapshots)) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let lines = all.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    public static func load(diskID: String? = nil, base: URL? = nil) -> [SMARTSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let all = readSnapshots(at: fileURL(base: base))
        guard let diskID else { return all }
        return all.filter { $0.diskID == diskID }
    }

    public static func clear(diskID: String? = nil, base: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(base: base)
        guard let diskID else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let remaining = readSnapshots(at: url).filter { $0.diskID != diskID }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let lines = remaining.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 从报告行抽取指标。优先用稳定 key，旧版后端没有 key 时退回中文标签。
    public static func makeSnapshot(from report: ReportDTO, at date: Date = Date()) -> SMARTSnapshot {
        let rows = report.sections.flatMap(\.rows)
        var metrics: [SMARTMetricValue] = []
        for definition in SMARTMetricDefinition.allCases {
            let row = rows.first { $0.key == definition.key }
                ?? rows.first { r in
                    guard let key = r.key else { return definition.aliases.contains(r.label) }
                    return false
                }
            guard let row, let value = row.numeric else { continue }
            metrics.append(SMARTMetricValue(
                key: definition.key,
                label: row.label.isEmpty ? definition.label : row.label,
                value: value,
                unit: definition.unit
            ))
        }
        return SMARTSnapshot(
            date: date,
            diskID: report.device.id,
            diskLabel: report.device.label,
            status: report.status,
            metrics: metrics
        )
    }

    private static func readSnapshots(at url: URL) -> [SMARTSnapshot] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return text.split(separator: "\n").compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SMARTSnapshot.self, from: data)
        }
    }
}

// MARK: - 分析

public enum SMARTAnalysis {
    /// 对最新采样做阈值判断，按严重程度排序。
    public static func alerts(in snapshot: SMARTSnapshot) -> [SMARTAlert] {
        var result: [SMARTAlert] = []
        for metric in snapshot.metrics {
            guard let definition = SMARTMetricDefinition.allCases.first(where: { $0.key == metric.key }),
                  let level = definition.level(for: metric.value) else { continue }
            let limitText: String
            switch definition {
            case .temperature: limitText = "≥45°C 警告，≥55°C 严重"
            case .availableSpare: limitText = "≤20% 警告，≤10% 严重"
            case .percentageUsed: limitText = "≥80% 警告，≥95% 严重"
            case .mediaErrors: limitText = "出现即严重"
            case .errorLogEntries: limitText = "出现即警告"
            case .reallocated, .pending, .uncorrectable: limitText = ">0 警告，≥10 严重"
            case .powerOnHours: limitText = ""
            }
            result.append(SMARTAlert(
                key: metric.key,
                title: "\(metric.label) \(format(metric.value))\(metric.unit)",
                detail: "阈值：\(limitText)",
                level: level,
                value: metric.value
            ))
        }
        return result.sorted { lhs, rhs in
            lhs.level == .critical && rhs.level != .critical
        }
    }

    /// 指定指标的完整历史序列（按时间升序）。
    public static func series(for snapshots: [SMARTSnapshot], key: String) -> [SMARTSeriesPoint] {
        snapshots.compactMap { snapshot in
            guard let metric = snapshot.metric(key) else { return nil }
            return SMARTSeriesPoint(date: snapshot.date, value: metric.value)
        }
    }

    private static func format(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.005
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
