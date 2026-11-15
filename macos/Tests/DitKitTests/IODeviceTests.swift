import XCTest
import Foundation
@testable import DitKitCore

final class IODeviceTests: XCTestCase {

    // MARK: - 设备标注（外置机械盘要能一眼认出来）

    func testDisplayNameDistinguishesExternalRotationalDisk() {
        let ssd = IODevice(key: "disk0", model: "APPLE SSD AP2048Z",
                           isInternal: true, mediumType: "Solid State",
                           capacityBytes: 2_000_000_000_000)
        let hdd = IODevice(key: "disk4", model: "EZEX-08WN4A0",
                           isInternal: false, mediumType: "Rotational",
                           capacityBytes: 1_000_204_886_016)
        XCTAssertEqual(ssd.kindLabel, "固态硬盘")
        XCTAssertEqual(ssd.locationLabel, "内置")
        XCTAssertEqual(hdd.kindLabel, "机械硬盘")
        XCTAssertEqual(hdd.locationLabel, "外置")
        XCTAssertTrue(hdd.displayName.contains("disk4"))
        XCTAssertTrue(hdd.displayName.contains("外置机械硬盘"))
        XCTAssertTrue(hdd.displayName.contains("EZEX-08WN4A0"))
        XCTAssertFalse(hdd.capacityText.isEmpty)
        let unknown = IODevice(key: "disk9")
        XCTAssertEqual(unknown.kindLabel, "磁盘")
    }

    // MARK: - 按盘聚合（纯逻辑）

    func testAggregateSelectedDeviceOnly() {
        let t = Date(timeIntervalSince1970: 1_000)
        let internalDisk = IODeviceSnapshot(
            key: "disk0", bsdName: "disk0",
            counters: IOCounters(readBytes: 100, writeBytes: 10,
                                 readOps: 5, writeOps: 2, timestamp: t)
        )
        let externalDisk = IODeviceSnapshot(
            key: "disk4", bsdName: "disk4",
            counters: IOCounters(readBytes: 7, writeBytes: 3,
                                 readOps: 1, writeOps: 1, timestamp: t)
        )
        let all = IOAggregate.total([internalDisk, externalDisk], key: nil, timestamp: t)
        XCTAssertEqual(all.readBytes, 107)
        XCTAssertEqual(all.writeBytes, 13)
        XCTAssertEqual(all.readOps, 6)

        let externalOnly = IOAggregate.total(
            [internalDisk, externalDisk], key: "disk4", timestamp: t
        )
        XCTAssertEqual(externalOnly.readBytes, 7)
        XCTAssertEqual(externalOnly.writeBytes, 3)
        XCTAssertEqual(externalOnly.readOps, 1)

        let missing = IOAggregate.total(
            [internalDisk, externalDisk], key: "disk9", timestamp: t
        )
        XCTAssertEqual(missing.readBytes, 0)
        XCTAssertEqual(missing.timestamp, t)
    }

    // MARK: - 真机：只返回物理盘，不再把 APFS 合成盘算一遍

    func testSnapshotContainsOnlyPhysicalDisks() {
        let devices = IOKitCounters.devices()
        let snapshots = IOKitCounters.snapshot()
        print("[DitKit] 物理磁盘：\(devices.map(\.displayName))")
        XCTAssertFalse(devices.isEmpty, "当前 Mac 至少应识别出一块物理磁盘")
        let keys = Set(devices.map(\.key))
        XCTAssertTrue(snapshots.allSatisfy { keys.contains($0.key) },
                      "快照不应包含 APFS 合成盘 / 虚拟盘")
        XCTAssertEqual(Set(snapshots.map(\.key)).count, snapshots.count,
                       "同一块物理盘不应出现重复 key")
        XCTAssertFalse(devices.contains { $0.model.contains("AppleAPFS") })
        let total = IOAggregate.total(snapshots, key: nil, timestamp: Date())
        let manual = snapshots.reduce(UInt64(0)) { $0 + $1.counters.readBytes }
        XCTAssertEqual(total.readBytes, manual, "合计值必须等于各物理盘之和")
    }
}
