import XCTest
import Foundation
@testable import DitKitCore

final class SMARTHistoryTests: XCTestCase {
    private func tempBase(_ name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitSMARTHistory_\(name)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func report(temperature: Double, diskID: String = "disk_test") -> ReportDTO {
        let json = """
        {
          "device":{"id":"\(diskID)","name":"/dev/disk0","type":"nvme","protocol":"NVMe","label":"测试盘"},
          "overall":"需要注意","status":"warn","summary":"有告警","generated_at":"2026 年 11 月 17 日 22:00:00",
          "sections":[{"title":"三、NVMe 健康信息明细","rows":[
            {"key":"nvme_temperature","label":"当前温度","value":"50 摄氏度","numeric":\(temperature),"status":"warn"},
            {"key":"nvme_media_errors","label":"介质错误","value":"1 次","numeric":1,"status":"critical"},
            {"key":"nvme_power_on_hours","label":"累计通电时间","value":"100 小时","numeric":100,"status":"info"}
          ]}],
          "warnings":[],"messages":[],"exit_code":0,"exit_notes":[]
        }
        """
        return try! JSONDecoder().decode(ReportDTO.self, from: Data(json.utf8))
    }

    func testRecordDeduplicatesAndLoadsByDisk() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        XCTAssertTrue(SMARTHistory.record(report(temperature: 40), at: now, base: base))
        XCTAssertFalse(SMARTHistory.record(report(temperature: 41), at: now.addingTimeInterval(10), base: base),
                       "60 秒内的重复刷新不应重复记录")
        XCTAssertTrue(SMARTHistory.record(report(temperature: 50),
                                          at: now.addingTimeInterval(120), base: base))
        XCTAssertTrue(SMARTHistory.record(report(temperature: 30, diskID: "disk_other"),
                                          at: now.addingTimeInterval(180), base: base))

        let all = SMARTHistory.load(base: base)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(SMARTHistory.load(diskID: "disk_test", base: base).count, 2)
        XCTAssertEqual(SMARTHistory.load(diskID: "disk_other", base: base).count, 1)
        XCTAssertEqual(all.last?.metric("nvme_temperature")?.value, 30)
    }

    func testSnapshotUsesBackendNumericInsteadOfParsingChineseText() {
        let snapshot = SMARTHistory.makeSnapshot(from: report(temperature: 47.5))
        XCTAssertEqual(snapshot.diskID, "disk_test")
        XCTAssertEqual(snapshot.metric("nvme_temperature")?.value, 47.5)
        XCTAssertEqual(snapshot.metric("nvme_temperature")?.unit, "°C")
        XCTAssertNotNil(snapshot.metric("nvme_power_on_hours"))
    }

    func testAlertsAndSeries() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        _ = SMARTHistory.record(report(temperature: 40), at: now, base: base)
        _ = SMARTHistory.record(report(temperature: 60), at: now.addingTimeInterval(120), base: base)
        let history = SMARTHistory.load(diskID: "disk_test", base: base)

        let alerts = SMARTAnalysis.alerts(in: SMARTHistory.makeSnapshot(from: report(temperature: 60)))
        XCTAssertEqual(alerts.first?.level, .critical, "严重项应排在最前")
        XCTAssertTrue(alerts.contains { $0.key == "nvme_temperature" })
        XCTAssertTrue(alerts.contains { $0.key == "nvme_media_errors" })

        let series = SMARTAnalysis.series(for: history, key: "nvme_temperature")
        XCTAssertEqual(series.map(\.value), [40, 60])
    }

    func testClearOneDiskKeepsOthers() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        _ = SMARTHistory.record(report(temperature: 40), at: now, base: base)
        _ = SMARTHistory.record(report(temperature: 40, diskID: "disk_other"), base: base)
        SMARTHistory.clear(diskID: "disk_test", base: base)
        XCTAssertEqual(SMARTHistory.load(base: base).map(\.diskID), ["disk_other"])
    }
}
