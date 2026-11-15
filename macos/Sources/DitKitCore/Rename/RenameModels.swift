import Foundation

/// 拍摄时间的来源，用于界面显示与兜底说明。
public enum CaptureTimeSource: String, Sendable {
    case exif = "EXIF"
    case video = "视频元数据"
    case file = "文件时间"
}

public struct CaptureInfo: Sendable {
    public let date: Date
    public let subsecondRaw: String?
    public let cameraModel: String?
    public let source: CaptureTimeSource

    public init(date: Date, subsecondRaw: String?, cameraModel: String?, source: CaptureTimeSource) {
        self.date = date
        self.subsecondRaw = subsecondRaw
        self.cameraModel = cameraModel
        self.source = source
    }
}

/// 毫秒三位的来源：EXIF 原始三位 / EXIF 不足三位补零 / EXIF 缺失时用系统时间。
public enum MillisecondSource: String, Sendable {
    case exif = "EXIF"
    case exifPadded = "EXIF 补零"
    case system = "系统时间"
}

public enum RenameItemState: Equatable, Sendable {
    case pending
    case unchanged
    case renamed
    case skipped(String)
    case failed(String)

    public var label: String {
        switch self {
        case .pending: return "待处理"
        case .unchanged: return "无需改动"
        case .renamed: return "已重命名"
        case .skipped(let why): return "跳过：\(why)"
        case .failed(let why): return "失败：\(why)"
        }
    }
}

public struct RenameItem: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let directory: URL
    public let originalName: String
    public let parentName: String
    public let capture: CaptureInfo?
    public let captureDateText: String
    public let millisecond: String
    public let millisecondSource: MillisecondSource
    public let proposedName: String
    public var state: RenameItemState

    public init(
        id: UUID = UUID(),
        url: URL,
        capture: CaptureInfo?,
        captureDateText: String,
        millisecond: String,
        millisecondSource: MillisecondSource,
        proposedName: String,
        state: RenameItemState = .pending
    ) {
        self.id = id
        self.url = url
        self.directory = url.deletingLastPathComponent()
        self.originalName = url.lastPathComponent
        self.parentName = url.deletingLastPathComponent().lastPathComponent
        self.capture = capture
        self.captureDateText = captureDateText
        self.millisecond = millisecond
        self.millisecondSource = millisecondSource
        self.proposedName = proposedName
        self.state = state
    }
}

public struct RenameOutcome: Sendable {
    public let renamed: Int
    public let unchanged: Int
    public let failed: Int
    public let messages: [String]
}

/// 纯命名逻辑集中在这里，方便单元测试覆盖，不触碰文件系统。
public enum RenameFormatter {
    /// 年月日_时分秒，例如 20261109_224503。用 Calendar 手动拼装，避免 DateFormatter 的时区/线程问题。
    public static func timestamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d_%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// EXIF 子秒 → 三位毫秒。
    /// - 两位补一个 0（"12" → "120"），一位补两个 0，三位及以上取前三位；
    /// - 字段缺失或全是非法字符时使用系统当前时间的毫秒。
    public static func millisecond(raw: String?, systemNow: Date = Date()) -> (String, MillisecondSource) {
        let digits = (raw ?? "").unicodeScalars
            .filter { $0.value >= 48 && $0.value <= 57 }
            .map { Character($0) }
        if digits.isEmpty {
            return (systemMillisecond(systemNow), .system)
        }
        if digits.count >= 3 {
            return (String(digits.prefix(3)), .exif)
        }
        return (String(digits).padding(toLength: 3, withPad: "0", startingAt: 0), .exifPadded)
    }

    public static func systemMillisecond(_ date: Date = Date()) -> String {
        let nanos = Calendar.current.component(.nanosecond, from: date)
        return String(format: "%03d", min(999, nanos / 1_000_000))
    }

    /// 自定义段：去掉首尾空白、替换文件名非法字符、限长 60。
    public static func sanitizeCustom(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var cleaned = ""
        for scalar in trimmed.unicodeScalars {
            cleaned.append(illegal.contains(scalar) ? "-" : Character(scalar))
        }
        return String(cleaned.prefix(60))
    }

    /// 年月日_时分秒_毫秒[_自定义].扩展名
    public static func fileName(date: Date, millisecond: String, custom: String, extension ext: String) -> String {
        var base = "\(timestamp(date))_\(millisecond)"
        let suffix = sanitizeCustom(custom)
        if !suffix.isEmpty { base += "_\(suffix)" }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// 目标名冲突时追加 -1 / -2 …；若生成的名字正好等于自己原文件名则直接沿用。
    public static func uniqueName(desired: String, original: String, used: inout Set<String>) -> String {
        if desired == original {
            used.insert(desired)
            return desired
        }
        let ns = desired as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = desired
        var index = 1
        while used.contains(candidate) {
            candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }
}
