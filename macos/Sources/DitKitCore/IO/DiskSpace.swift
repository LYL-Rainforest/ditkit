import Foundation
import Darwin

/// 一个已挂载卷的容量信息（含外置卷）。
public struct VolumeInfo: Sendable, Equatable, Identifiable {
    public let url: URL
    public let name: String
    public let path: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let fileSystemType: String
    public let isRoot: Bool
    public let isLocal: Bool
    public let isRemovable: Bool

    public var id: String { path }
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    public var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    public init(url: URL, name: String, path: String, totalBytes: Int64, freeBytes: Int64,
                fileSystemType: String, isRoot: Bool, isLocal: Bool, isRemovable: Bool) {
        self.url = url
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.fileSystemType = fileSystemType
        self.isRoot = isRoot
        self.isLocal = isLocal
        self.isRemovable = isRemovable
    }
}

/// 目录树节点。size 为 nil 表示尚未统计——这是按需加载的核心：
/// 列目录时只读一层、不递归，占用大小在展开或后台填充时才计算。
public struct DiskEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64?

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int64?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// 某个顶层子项（文件或目录）累计占用的字节数（兼容旧接口）。
public struct LargeDirectoryEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let bytes: Int64

    public var id: String { path }

    public init(name: String, path: String, bytes: Int64) {
        self.name = name
        self.path = path
        self.bytes = bytes
    }
}

/// 只读的卷容量枚举与目录占用扫描；不执行任何外部命令、不需要 root。
public enum DiskSpaceScanner {
    /// 当前所有已挂载卷（跳过隐藏卷）。
    public static func volumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey,
                .volumeIsLocalKey, .volumeIsRemovableKey
            ])
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            // 重要用途可用空间更贴近用户实际可写容量；不支持时退回普通可用容量。
            let free = values?.volumeAvailableCapacityForImportantUsage
                ?? Int64(values?.volumeAvailableCapacity ?? 0)
            return VolumeInfo(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                path: url.path,
                totalBytes: total,
                freeBytes: free,
                fileSystemType: fileSystemType(at: url),
                isRoot: values?.volumeIsRootFileSystem ?? false,
                isLocal: values?.volumeIsLocal ?? true,
                isRemovable: values?.volumeIsRemovable ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 目标路径所在卷的可用字节数（供文件传输空间预检复用）。
    public static func freeBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        var probe = url
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// 只读取目录的直接子项——**不递归**，所以在大卷上也是秒级。
    /// 目录项的 size 为 nil（等展开时再统计），文件项直接给出自身占用。
    /// 隐藏项与符号链接一律跳过，避免跟着链接跑出卷外。
    public static func children(
        of directory: URL,
        isCancelled: () -> Bool = { false }
    ) -> [DiskEntry] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey
        ]
        let urls = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []

        var result: [DiskEntry] = []
        for url in urls {
            if isCancelled() { break }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            let isDir = values.isDirectory ?? false
            let size = isDir ? nil : max(0, Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0))
            result.append(DiskEntry(
                name: url.lastPathComponent, path: url.path, isDirectory: isDir, size: size
            ))
        }
        // 目录在前、同类按名称排，便于逐级浏览。
        return result.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 列出一层并按占用大小降序排好；目录的大小在此递归统计出来。
    /// - parameter limit: 只保留前 N 项；nil 表示全部保留（用于展开后的子目录）。
    /// - parameter onProgress: 每统计完一个目录回调 (已完成数, 目录总数)。
    /// 这是让界面「统计完再排」的核心：返回时每一项都带确定的 size。
    public static func rankedChildren(
        in directory: URL,
        limit: Int? = nil,
        isCancelled: () -> Bool = { false },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> [DiskEntry] {
        let items = children(of: directory, isCancelled: isCancelled)
        guard !items.isEmpty else { return [] }

        let dirs = items.filter { $0.isDirectory }
        var measured: [String: Int64] = [:]
        for (index, dir) in dirs.enumerated() {
            if isCancelled() { break }
            measured[dir.path] = recursiveSize(of: URL(fileURLWithPath: dir.path),
                                               isCancelled: isCancelled)
            onProgress(index + 1, dirs.count)
        }

        let ranked = items.map { item -> DiskEntry in
            let size = item.isDirectory ? (measured[item.path] ?? 0) : (item.size ?? 0)
            return DiskEntry(name: item.name, path: item.path,
                             isDirectory: item.isDirectory, size: size)
        }
        .sorted { ($0.size ?? 0) > ($1.size ?? 0) }

        if let limit { return Array(ranked.prefix(max(0, limit))) }
        return ranked
    }

    /// 递归统计一个目录子树占用的总字节数（只在展开/按需统计时调用）。
    /// 性能要点：不再对每个文件做 `resolvingSymlinksInPath()`（逐组件 realpath 是原先最慢的一环）；
    /// 这里只用枚举器预取的属性判断符号链接并累加，无需比较路径。
    public static func recursiveSize(
        of directory: URL,
        isCancelled: () -> Bool = { false }
    ) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey
        ]
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            total += max(0, Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0))
        }
        return total
    }

    /// 扫描目录下各顶层子项的累计大小，返回占用最大的若干项（兼容旧接口）。
    /// 现在复用「先列一层 + 按需统计」，不再一次性全卷递归。
    public static func topEntries(
        in root: URL,
        limit: Int = 20,
        isCancelled: () -> Bool = { false }
    ) -> [LargeDirectoryEntry] {
        let kids = children(of: root, isCancelled: isCancelled)
        var out: [LargeDirectoryEntry] = []
        for kid in kids {
            if isCancelled() { break }
            let bytes: Int64
            if kid.isDirectory {
                bytes = recursiveSize(of: URL(fileURLWithPath: kid.path), isCancelled: isCancelled)
            } else {
                bytes = kid.size ?? 0
            }
            out.append(LargeDirectoryEntry(name: kid.name, path: kid.path, bytes: bytes))
        }
        return out
            .sorted { $0.bytes > $1.bytes }
            .prefix(max(0, limit))
            .map { $0 }
    }

    // MARK: - 工具

    private static func fileSystemType(at url: URL) -> String {
        var info = statfs()
        guard url.path.withCString({ statfs($0, &info) }) == 0 else { return "" }
        let capacity = MemoryLayout.size(ofValue: info.f_fstypename) / MemoryLayout<CChar>.size
        return withUnsafePointer(to: &info.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                String(cString: chars)
            }
        }
    }
}
