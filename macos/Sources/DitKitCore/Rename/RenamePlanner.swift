import Foundation

/// 拖入项的展开、预览生成与原地执行。纯逻辑在 RenameFormatter，这里只碰文件系统。
public enum RenamePlanner {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw",
    ]
    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts",
    ]
    public static var supportedExtensions: Set<String> {
        imageExtensions.union(videoExtensions)
    }

    public static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 展开拖入项：单个/多个文件直接收，目录递归遍历子目录；
    /// 跳过隐藏文件、包内容、不支持的扩展名，并按标准化路径去重。
    public static func expand(_ inputs: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            result.append(standardized)
        }

        for input in inputs {
            let url = input.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let child as URL in enumerator {
                    guard !child.lastPathComponent.hasPrefix(".") else { continue }
                    var childIsDirectory: ObjCBool = false
                    fm.fileExists(atPath: child.path, isDirectory: &childIsDirectory)
                    if !childIsDirectory.boolValue && isSupported(child) { append(child) }
                }
            } else if isSupported(url) {
                append(url)
            }
        }
        return result
    }

    /// 带控制信息的扫描结果。停止时不返回部分预览：命名冲突需要完整文件集合才能算准。
    public struct PreviewOutcome: Sendable {
        public let items: [RenameItem]
        public let stopped: Bool
    }

    /// 读取所有文件的拍摄时间，生成新文件名预览（无控制版本，供测试与常规调用）。
    public static func preview(for urls: [URL], custom: String, now: Date = Date()) async -> [RenameItem] {
        await previewControlled(for: urls, custom: custom, now: now,
                                control: nil, onProgress: nil).items
    }

    /// 读取所有文件的拍摄时间，生成新文件名预览。冲突按「各自所在目录」独立判断。
    /// `control` 在每个文件的 EXIF 读取前检查暂停/停止；`onProgress` 回报 (已完成, 总数)。
    public static func previewControlled(
        for urls: [URL],
        custom: String,
        now: Date = Date(),
        control: RunControl?,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> PreviewOutcome {
        let total = urls.count
        let collected: [(String, CaptureInfo?)] = await withTaskGroup(
            of: (String, CaptureInfo?).self,
            returning: [(String, CaptureInfo?)].self
        ) { group in
            for url in urls {
                let key = url.standardizedFileURL.path
                group.addTask {
                    if let control, !(await control.gate()) { return (key, nil) }
                    return (key, await EXIFReader.read(url: url))
                }
            }
            var results: [(String, CaptureInfo?)] = []
            var done = 0
            for await pair in group {
                results.append(pair)
                done += 1
                await onProgress?(done, total)
            }
            return results
        }
        if control?.isStopped == true { return PreviewOutcome(items: [], stopped: true) }
        var infos: [String: CaptureInfo?] = [:]
        for (key, info) in collected { infos[key] = info }

        let fm = FileManager.default
        var usedByDirectory: [String: Set<String>] = [:]
        var items: [RenameItem] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let directory = url.deletingLastPathComponent()
            let dirKey = directory.standardizedFileURL.path
            if usedByDirectory[dirKey] == nil {
                let existing = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
                usedByDirectory[dirKey] = Set(existing)
            }
            let capture: CaptureInfo? = infos[url.standardizedFileURL.path] ?? nil
            let date = capture?.date ?? now
            let (millisecond, msSource) = RenameFormatter.millisecond(
                raw: capture?.subsecondRaw,
                systemNow: now
            )
            let desired = RenameFormatter.fileName(
                date: date,
                millisecond: millisecond,
                custom: custom,
                extension: url.pathExtension
            )
            var used = usedByDirectory[dirKey] ?? []
            let proposed = RenameFormatter.uniqueName(
                desired: desired,
                original: url.lastPathComponent,
                used: &used
            )
            usedByDirectory[dirKey] = used

            let dateText = "\(RenameFormatter.timestamp(date)) · \(capture?.source.rawValue ?? "系统时间")"
            items.append(RenameItem(
                url: url,
                capture: capture,
                captureDateText: dateText,
                millisecond: millisecond,
                millisecondSource: msSource,
                proposedName: proposed
            ))
        }
        return PreviewOutcome(items: items, stopped: false)
    }

    /// 原地执行重命名（可暂停 / 停止）。执行前再次检查目标是否存在，避免预览后被其它进程占用。
    ///
    /// 控制点在**文件边界**：当前文件改名完成后才响应暂停/停止，停止后剩余项保持 `.pending`，
    /// 由调用方据 `control.isStopped` 生成只包含已完成项的部分报告。
    public static func apply(
        _ items: [RenameItem],
        control: RunControl? = nil,
        onProgress: (@MainActor (Int, Int, String) -> Void)? = nil
    ) async -> (RenameOutcome, [RenameItem]) {
        let fm = FileManager.default
        var updated = items
        var renamed = 0
        var unchanged = 0
        var failed = 0
        var messages: [String] = []
        var processed = 0

        for index in updated.indices {
            if let control, !(await control.gate()) { break }
            let item = updated[index]
            processed += 1
            await onProgress?(processed, items.count, item.originalName)
            guard item.state == .pending else { continue }
            let target = item.directory.appendingPathComponent(item.proposedName)
            if target.standardizedFileURL.path == item.url.standardizedFileURL.path {
                updated[index].state = .unchanged
                unchanged += 1
                continue
            }
            if fm.fileExists(atPath: target.path) {
                updated[index].state = .failed("目标文件已存在")
                failed += 1
                messages.append("\(item.originalName)：目标已存在")
                continue
            }
            do {
                try fm.moveItem(at: item.url, to: target)
                updated[index].state = .renamed
                renamed += 1
            } catch {
                updated[index].state = .failed(error.localizedDescription)
                failed += 1
                messages.append("\(item.originalName)：\(error.localizedDescription)")
            }
        }
        return (
            RenameOutcome(renamed: renamed, unchanged: unchanged, failed: failed, messages: messages),
            updated
        )
    }
}
