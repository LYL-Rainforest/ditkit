import Foundation
import ImageIO
import AVFoundation

/// 按优先级读取拍摄时间：图片 EXIF → 视频元数据 → 文件时间兜底。
/// EXIF 的 DateTimeOriginal 没有时区信息，按系统本地时区解释（与文件名格式化用的 Calendar 一致）。
public enum EXIFReader {
    public static func read(url: URL) async -> CaptureInfo? {
        if let image = readImage(url) { return image }
        if RenamePlanner.isVideo(url), let video = await readVideo(url) { return video }
        return readFile(url)
    }

    // MARK: - 图片（ImageIO）

    private static func readImage(_ url: URL) -> CaptureInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        return capture(fromProperties: props)
    }

    /// 从 ImageIO 属性字典解析拍摄时间。公开这个入口是为了让单元测试能直接注入
    /// 带 SubSecTimeOriginal 的 EXIF 字典（ImageIO 写入端会丢弃它不认识的子秒键）。
    public static func capture(fromProperties props: [String: Any]) -> CaptureInfo? {
        guard let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return nil
        }
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let model = tiff?[kCGImagePropertyTIFFModel as String] as? String
        // ImageIO 没有为所有 EXIF 子秒 tag 导出 Swift 常量，直接使用 EXIF 标准键名。
        guard let rawDate = stringValue(exif["DateTimeOriginal"])
            ?? stringValue(exif["DateTimeDigitized"]) else { return nil }
        // 兼容 "2026:11:09 22:45:03.12"：小数秒也是常见的子秒写法。
        let (datePart, fractional) = splitDateTime(rawDate)
        guard let date = parseEXIFDate(datePart) else { return nil }
        let rawSubsecond = stringValue(exif["SubSecTimeOriginal"])
            ?? stringValue(exif["SubSecTimeDigitized"])
            ?? stringValue(exif["SubSecTime"])
            ?? fractional
        return CaptureInfo(date: date, subsecondRaw: rawSubsecond, cameraModel: model, source: .exif)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func splitDateTime(_ raw: String) -> (String, String?) {
        guard let dot = raw.lastIndex(of: ".") else { return (raw, nil) }
        return (String(raw[..<dot]), String(raw[raw.index(after: dot)...]))
    }

    private static func parseEXIFDate(_ raw: String) -> Date? {
        for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    // MARK: - 视频（AVFoundation 创建日期）

    private static func readVideo(_ url: URL) async -> CaptureInfo? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let identifiers: [AVMetadataIdentifier] = [
            .commonIdentifierCreationDate,
            .quickTimeMetadataCreationDate,
        ]
        for identifier in identifiers {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            if let item = items.first, let date = try? await item.load(.dateValue) {
                return CaptureInfo(date: date, subsecondRaw: nil, cameraModel: nil, source: .video)
            }
        }
        return nil
    }

    // MARK: - 兜底：文件时间

    private static func readFile(_ url: URL) -> CaptureInfo? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let date = values?.contentModificationDate ?? values?.creationDate ?? Date()
        return CaptureInfo(date: date, subsecondRaw: nil, cameraModel: nil, source: .file)
    }
}
