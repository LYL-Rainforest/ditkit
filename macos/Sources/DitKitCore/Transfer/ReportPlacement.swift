import Foundation

/// 报告文件的存放位置。两个开关独立：可只选同目录、只选自定义目录、两者都选，或都不选。
///
/// - **同目录**：传输=每个目标目录根；重命名=每个发生改动的目录根（现有默认行为）。
/// - **自定义目录**：所有报告平铺到同一目录；文件名追加来源目录标识，避免多个目标/目录互相覆盖。
/// - **都不选**：不生成任何报告文件（界面仍显示统计结果）。
public struct ReportPlacement: Sendable, Equatable {
    /// 是否写到报告的自然归属目录（目标根 / 被改动目录）。
    public var writeAlongside: Bool
    /// 是否勾选「自定义目录」。独立于路径，供复选框直接绑定。
    public var useCustomDirectory: Bool
    /// 自定义目录路径字符串；支持 `~` 展开。真正生效还需 `useCustomDirectory == true` 且路径非空。
    public var customDirectory: String

    /// - parameter useCustomDirectory: 显式勾选状态；为 nil 时按 `customDirectory` 是否非空推断（兼容旧调用）。
    public init(writeAlongside: Bool = true, customDirectory: String = "", useCustomDirectory: Bool? = nil) {
        self.writeAlongside = writeAlongside
        self.customDirectory = customDirectory
        self.useCustomDirectory = useCustomDirectory
            ?? !customDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 默认：只写同目录，保持既有行为。
    public static var `default`: ReportPlacement { ReportPlacement() }

    /// 解析后的自定义目录 URL（勾选生效、去空白、展开 `~`）；未生效时为 nil。
    public var customURL: URL? {
        guard useCustomDirectory else { return nil }
        let trimmed = customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// 是否要生成报告文件。
    public var producesReports: Bool { writeAlongside || customURL != nil }

    /// 一个实际写入位置：目录 + 该处使用的文件名前缀。
    public struct Output: Sendable, Equatable {
        public let directory: URL
        public let filePrefix: String
        public init(directory: URL, filePrefix: String) {
            self.directory = directory
            self.filePrefix = filePrefix
        }
    }

    /// 为一个「自然归属目录」计算所有写入位置。
    /// - parameter natural: 报告默认归属目录（传输=目标根，重命名=被改动目录）。
    /// - parameter basePrefix: 基础文件名前缀（不含来源标识）。
    /// - returns: 同目录直接用基础前缀（保持旧文件名与清理规则）；自定义目录追加来源目录标识以区分平铺文件。
    public func outputs(natural: URL, basePrefix: String) -> [Output] {
        var result: [Output] = []
        if writeAlongside {
            result.append(Output(directory: natural, filePrefix: basePrefix))
        }
        if let custom = customURL {
            let tagged = basePrefix + "__" + Self.sourceToken(for: natural)
            result.append(Output(directory: custom, filePrefix: tagged))
        }
        return result
    }

    /// 来源目录的稳定文件名标识：目录名 + 完整路径的短哈希。
    /// 同一目录跨运行得到相同结果；同名但不同路径的目录不会互相覆盖。
    public static func sourceToken(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        var name = url.lastPathComponent
        if name.isEmpty { name = "root" }
        // 文件名安全化：只保留字母数字、中文、下划线、连字符，其余换成下划线。
        let safe = String(name.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { return ch }
            return "_"
        })
        return safe + "_" + fnv1aHex(path)
    }

    /// FNV-1a 64 位哈希，取低 8 位十六进制。稳定（非随机种子），适合做文件名后缀。
    private static func fnv1aHex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let low = UInt32(truncatingIfNeeded: hash)
        return String(format: "%08x", low)
    }
}
