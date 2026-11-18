import Foundation
import IOKit
import DiskArbitration

/// 启动卷信息，用于面板顶部的容量条。
public struct IOVolumeInfo: Sendable, Equatable {
    public let name: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let bsdNames: [String]

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public var summary: String {
        "启动卷 \(name) · 已用 \(IOFormat.capacity(usedBytes)) · 剩余 \(IOFormat.capacity(freeBytes)) · 总量 \(IOFormat.capacity(totalBytes))"
    }
}

/// 只读 IOKit / DiskArbitration，不执行任何外部命令、不需要 root。
///
/// 数据来源：`IOBlockStorageDriver` 的 "Statistics" 字典（累计读写字节/次数）。
/// **只统计物理盘**：provider 必须是 `IOBlockStorageDevice`，这样可排除挂在物理盘分区之上的
/// APFS 合成盘（disk3 / disk5 之类）。否则同一份 IO 会在物理盘与合成盘上各记一次，
/// `aggregate()` 得到的总吞吐接近翻倍，外置机械盘的真实数值会被完全淹没。
public enum IOKitCounters {
    private static let driverClass = "IOBlockStorageDriver"
    private static let deviceClass = "IOBlockStorageDevice"
    private static let statisticsKey = "Statistics" as CFString
    private static let bsdNameKey = "BSD Name" as CFString
    private static let characteristicsKey = "Device Characteristics" as CFString

    /// 当前所有**物理盘**的累计计数器快照。
    public static func snapshot() -> [IODeviceSnapshot] {
        let now = Date()
        var result: [IODeviceSnapshot] = []
        forEachPhysicalDriver { entry, _, bsd in
            let raw = statistics(of: entry)
            let counters = IOCounters(
                readBytes: uint(raw["Bytes (Read)"]),
                writeBytes: uint(raw["Bytes (Write)"]),
                readOps: uint(raw["Operations (Read)"]),
                writeOps: uint(raw["Operations (Write)"]),
                timestamp: now
            )
            result.append(IODeviceSnapshot(key: bsd, bsdName: bsd, counters: counters))
        }
        return result
    }

    /// 全部物理磁盘合计（已排除虚拟盘重复计数）。
    public static func aggregate() -> IOCounters {
        IOAggregate.total(snapshot(), key: nil, timestamp: Date())
    }

    /// 物理盘清单（含内置/外置、SSD/机械、型号、容量），供界面磁盘选择器使用。
    public static func devices() -> [IODevice] {
        var result: [IODevice] = []
        forEachPhysicalDriver { _, parent, bsd in
            let chars = characteristics(of: parent)
            let info = diskDescription(bsd)
            result.append(IODevice(
                key: bsd,
                bsdName: bsd,
                model: chars.model.isEmpty ? info.model : chars.model,
                isInternal: info.isInternal,
                mediumType: chars.medium,
                capacityBytes: info.capacity
            ))
        }
        return result.sorted { $0.key < $1.key }
    }

    public static func physicalDeviceNames() -> [String] {
        Array(Set(snapshot().map(\.bsdName))).sorted()
    }

    public static func volumeInfo() -> IOVolumeInfo {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        let total = (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey])
        return IOVolumeInfo(
            name: values?.volumeName ?? "Macintosh HD",
            totalBytes: total,
            freeBytes: free,
            bsdNames: physicalDeviceNames()
        )
    }

    // MARK: - IORegistry 遍历

    /// 只回调 provider 为 `IOBlockStorageDevice` 的驱动（即物理盘），并负责释放句柄。
    private static func forEachPhysicalDriver(
        _ body: (io_service_t, io_service_t, String) -> Void
    ) {
        guard let matching = IOServiceMatching(driverClass) else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(parent) }
            // APFS 合成盘 / FileVault / RAID 等虚拟盘的 provider 不是物理存储设备。
            guard conforms(parent, deviceClass) else { continue }
            let bsd = bsdName(of: entry)
            // 无介质的读卡器等没有 BSD Name，也不会产生 IO，直接忽略。
            guard !bsd.isEmpty else { continue }
            body(entry, parent, bsd)
        }
    }

    private static func conforms(_ object: io_service_t, _ className: String) -> Bool {
        let value = className.withCString { IOObjectConformsTo(object, $0) }
        return value != 0
    }

    private static func bsdName(of entry: io_service_t) -> String {
        (IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            bsdNameKey,
            kCFAllocatorDefault,
            UInt32(kIORegistryIterateRecursively)
        ) as? String) ?? ""
    }

    private static func statistics(of entry: io_service_t) -> [String: Any] {
        (IORegistryEntryCreateCFProperty(
            entry, statisticsKey, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    /// 物理存储设备的 Device Characteristics：Product Name / Medium Type。
    private static func characteristics(of device: io_service_t) -> (model: String, medium: String) {
        guard let raw = IORegistryEntryCreateCFProperty(
            device, characteristicsKey, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any] else { return ("", "") }
        return (
            raw["Product Name"] as? String ?? "",
            raw["Medium Type"] as? String ?? ""
        )
    }

    /// DiskArbitration 描述字典：内置/外置、型号、整盘容量。
    private static func diskDescription(_ bsd: String) -> (model: String, isInternal: Bool, capacity: Int64) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return ("", true, 0)
        }
        // 该 API 收 C 字符串而非 CFString。
        let disk = bsd.withCString {
            DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
        }
        guard let disk, let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return ("", true, 0)
        }
        let model = description["DADeviceModel"] as? String ?? ""
        let isInternal = (description["DADeviceInternal"] as? NSNumber)?.boolValue ?? true
        let capacity = (description["DAMediaSize"] as? NSNumber)?.int64Value ?? 0
        return (model, isInternal, capacity)
    }

    /// IORegistry 里的数字可能是 NSNumber（CFNumber），也可能是 64 位整数。
    private static func uint(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber { return number.uint64Value }
        if let number = value as? UInt64 { return number }
        if let number = value as? Int64 { return UInt64(max(0, number)) }
        if let number = value as? Int { return UInt64(max(0, number)) }
        return 0
    }
}
