import Foundation

// MARK: - 设备模型

/// 一块**物理**磁盘的展示信息（供实时 IO 页的磁盘选择器）。
/// `mediumType` 取自 IOKit 的 Device Characteristics："Solid State" / "Rotational"。
public struct IODevice: Sendable, Equatable, Identifiable {
    public let key: String
    public let bsdName: String
    public let model: String
    public let isInternal: Bool
    public let mediumType: String
    public let capacityBytes: Int64

    public var id: String { key }

    public init(key: String, bsdName: String = "", model: String = "",
                isInternal: Bool = true, mediumType: String = "", capacityBytes: Int64 = 0) {
        self.key = key
        self.bsdName = bsdName.isEmpty ? key : bsdName
        self.model = model
        self.isInternal = isInternal
        self.mediumType = mediumType
        self.capacityBytes = capacityBytes
    }

    public var isSSD: Bool { mediumType.lowercased() == "solid state" }
    public var isRotational: Bool { mediumType.lowercased() == "rotational" }

    public var kindLabel: String {
        if isSSD { return "固态硬盘" }
        if isRotational { return "机械硬盘" }
        return "磁盘"
    }

    public var locationLabel: String { isInternal ? "内置" : "外置" }

    public var displayName: String {
        var parts = [bsdName, locationLabel + kindLabel]
        if !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    public var capacityText: String {
        capacityBytes > 0 ? IOFormat.capacity(capacityBytes) : ""
    }
}

/// 一次 IOKit 快照里某块物理磁盘的累计计数器。
public struct IODeviceSnapshot: Sendable, Equatable {
    public let key: String
    public let bsdName: String
    public let counters: IOCounters

    public init(key: String, bsdName: String, counters: IOCounters) {
        self.key = key
        self.bsdName = bsdName
        self.counters = counters
    }
}

/// 按选中磁盘聚合（纯逻辑，便于单元测试）：key 为 nil 时合计全部物理盘。
public enum IOAggregate {
    public static func total(
        _ snapshots: [IODeviceSnapshot],
        key: String?,
        timestamp: Date
    ) -> IOCounters {
        var total = IOCounters(timestamp: timestamp)
        for snapshot in snapshots where key == nil || snapshot.key == key {
            total = total.combined(with: snapshot.counters)
        }
        return total
    }
}

// MARK: - 值模型

/// 某一时刻的累计计数器（开机以来）。IOKit 给的是累计值，速率必须靠两次快照做差。
public struct IOCounters: Sendable, Equatable {
    public var readBytes: UInt64
    public var writeBytes: UInt64
    public var readOps: UInt64
    public var writeOps: UInt64
    public var timestamp: Date

    public init(
        readBytes: UInt64 = 0,
        writeBytes: UInt64 = 0,
        readOps: UInt64 = 0,
        writeOps: UInt64 = 0,
        timestamp: Date = Date()
    ) {
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readOps = readOps
        self.writeOps = writeOps
        self.timestamp = timestamp
    }

    public static let zero = IOCounters(timestamp: .distantPast)

    /// 多台物理磁盘的统计量相加，时间戳沿用左侧。
    public func combined(with other: IOCounters) -> IOCounters {
        IOCounters(
            readBytes: readBytes + other.readBytes,
            writeBytes: writeBytes + other.writeBytes,
            readOps: readOps + other.readOps,
            writeOps: writeOps + other.writeOps,
            timestamp: timestamp
        )
    }
}

/// 一个采样点：单位时间内的读写吞吐与操作次数。
public struct IOSample: Sendable, Equatable, Identifiable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public let readOpsPerSecond: Double
    public let writeOpsPerSecond: Double

    public init(
        timestamp: Date = Date(),
        readBytesPerSecond: Double = 0,
        writeBytesPerSecond: Double = 0,
        readOpsPerSecond: Double = 0,
        writeOpsPerSecond: Double = 0
    ) {
        self.timestamp = timestamp
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOpsPerSecond = readOpsPerSecond
        self.writeOpsPerSecond = writeOpsPerSecond
    }
}

/// 面板上四个大数字。
public struct IOMetrics: Sendable, Equatable {
    public var readSpeed: Double
    public var writeSpeed: Double
    public var readIOPS: Double
    public var writeIOPS: Double

    public static let zero = IOMetrics(readSpeed: 0, writeSpeed: 0, readIOPS: 0, writeIOPS: 0)

    public var peakSpeed: Double { max(readSpeed, writeSpeed) }
}

// MARK: - 纯计算（不依赖 IOKit，便于单元测试）

public enum IORate {
    /// 由相邻两次累计计数器算出速率。计数器归零/重置视为 0，不产生负速率。
    public static func sample(from previous: IOCounters, to current: IOCounters) -> IOSample? {
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0, elapsed < 60 else { return nil }
        return IOSample(
            timestamp: current.timestamp,
            readBytesPerSecond: delta(current.readBytes, previous.readBytes) / elapsed,
            writeBytesPerSecond: delta(current.writeBytes, previous.writeBytes) / elapsed,
            readOpsPerSecond: delta(current.readOps, previous.readOps) / elapsed,
            writeOpsPerSecond: delta(current.writeOps, previous.writeOps) / elapsed
        )
    }

    public static func metrics(from sample: IOSample) -> IOMetrics {
        IOMetrics(
            readSpeed: sample.readBytesPerSecond,
            writeSpeed: sample.writeBytesPerSecond,
            readIOPS: sample.readOpsPerSecond,
            writeIOPS: sample.writeOpsPerSecond
        )
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> Double {
        current >= previous ? Double(current - previous) : 0
    }
}

// MARK: - 固定长度环形缓冲

public struct IOSeries: Sendable, Equatable {
    public let capacity: Int
    public private(set) var samples: [IOSample]

    public init(capacity: Int) {
        self.capacity = max(2, capacity)
        self.samples = []
    }

    public mutating func append(_ sample: IOSample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public mutating func clear() {
        samples.removeAll(keepingCapacity: true)
    }

    /// 当前窗口内读写速率的最大值，用于图表自动量程。
    public var peakBytesPerSecond: Double {
        samples.reduce(0) { max($0, max($1.readBytesPerSecond, $1.writeBytesPerSecond)) }
    }
}

// MARK: - 固定时间轴的网格刻度（纯计算，便于单元测试）

public enum IOGrid {
    /// 竖线间隔：每 2 分钟一条线。
    public static let stepSeconds = 120

    /// 从左到右返回每条竖线的横向比例与「多少分钟前」。
    /// 10 分钟窗口 → 10 / 8 / 6 / 4 / 2 / 0 分钟前，共 6 条线（含左右两端）。
    public static func verticalLines(windowSeconds: Int) -> [(ratio: Double, minutesAgo: Int)] {
        let step = stepSeconds
        let window = max(step, windowSeconds)
        let segments = max(1, Int((Double(window) / Double(step)).rounded()))
        return (0...segments).map { index in
            (Double(index) / Double(segments), (segments - index) * step / 60)
        }
    }

    public static func timeLabel(minutesAgo: Int) -> String {
        minutesAgo == 0 ? "现在" : "\(minutesAgo) 分钟前"
    }
}

// MARK: - 二进制字母格式化（1024 进制，B / KiB / MiB / GiB / TiB / PiB）

public enum IOFormat {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

    /// 速率：例如 19.9 MiB/秒。全项目统一二进制字母口径，与测速页一致。
    public static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/秒" }
        if bytesPerSecond < 1_024 { return String(format: "%.0f B/秒", bytesPerSecond) }
        let short = ["B/秒", "KiB/秒", "MiB/秒", "GiB/秒", "TiB/秒"]
        var value = bytesPerSecond
        var i = 0
        while value >= 1_024 && i < short.count - 1 {
            value /= 1_024
            i += 1
        }
        // 保留一位小数，不能用 %.0f 抹掉读数差异。
        return String(format: "%.1f", value) + " " + short[i]
    }

    /// 图表纵轴刻度，用二进制字母单位；保留一位小数，避免刻度被取整成同一个标签。
    public static func axis(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0" }
        var value = bytesPerSecond
        var i = 0
        while value >= 1_024 && i < units.count - 1 {
            value /= 1_024
            i += 1
        }
        return String(format: "%.1f", value) + " " + units[i] + "/秒"
    }

    /// 同一组刻度统一使用量程对应的单位，短单位便于排版。
    public static func axis(_ value: Double, ceiling: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        let short = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var i = 0
        var scale = ceiling
        while scale >= 1_024 && i < short.count - 1 {
            scale /= 1_024
            i += 1
        }
        var divisor = 1.0
        for _ in 0..<i { divisor *= 1_024 }
        let converted = value / divisor
        // 小数位按刻度间隔统一决定，同一组刻度不会出现「20 MiB/秒」与「8.0 MiB/秒」混排。
        let step = ceiling / divisor / 5
        let decimals: Int
        if step >= 1 {
            decimals = abs(step - step.rounded()) < 0.001 ? 0 : 1
        } else {
            decimals = step >= 0.1 ? 1 : 2
        }
        return String(format: "%.\(decimals)f", converted) + " " + short[i] + "/秒"
    }

    public static func ops(_ value: Double) -> String {
        String(format: "%.0f 次/秒", value.rounded())
    }

    /// 大数字主体与单位分开返回，方便视图用不同字号排版。
    public static func speedParts(_ bytesPerSecond: Double) -> (String, String) {
        let full = speed(bytesPerSecond)
        guard let space = full.lastIndex(of: " ") else { return (full, "") }
        return (String(full[..<space]), String(full[full.index(after: space)...]))
    }

    public static func capacity(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var i = 0
        while value >= 1_024 && i < units.count - 1 {
            value /= 1_024
            i += 1
        }
        // 整数容量不拖小数尾巴：2 TiB，而不是 2.00 TiB。
        let text = abs(value - value.rounded()) < 0.005
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
        return text + " " + units[i]
    }
}
