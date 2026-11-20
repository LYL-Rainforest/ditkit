import Foundation

/// 报告文件的统一命名规则：时间放在最前面，秒与毫秒之间用下划线分隔。
///
/// 文件名结构：`<时间戳>_<前缀>.<扩展名>`
/// - 时间戳格式：`yyyyMMdd_HHmmss_SSS`，例如 `20261120_105208_123`
/// - 完整示例：`20261120_105208_123_DitKit_传输报告_复制_xxh128.mhl`
///
/// 时间置顶有两个好处：Finder 里按名称排序即按时间排序；同一前缀的报告天然聚在一起。
public enum ReportNaming {
    /// 时间戳：年月日_时分秒_毫秒（毫秒前加下划线）。
    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// 完整文件名（含扩展名）：时间在前，前缀在后。
    /// - parameter filePrefix: 业务前缀（传输/重命名/自定义目录的来源标识已含在内）。
    public static func fileName(filePrefix: String, ext: String, at date: Date) -> String {
        "\(timestamp(date))_\(filePrefix).\(ext)"
    }

    /// 从文件名中解析时间戳前缀，供清理与保护逻辑识别（新旧命名都能认）。
    /// - returns: 去掉「时间戳_」之后的剩余部分；不是本工具生成的命名则返回 nil。
    public static func stripTimestamp(_ name: String) -> String? {
        // 新格式：yyyyMMdd_HHmmss_SSS_ （8位_6位_3位_）
        let pattern = #"^\d{8}_\d{6}_\d{3}_"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range.upperBound...])
    }
}
