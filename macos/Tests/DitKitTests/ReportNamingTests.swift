import XCTest
import Foundation
@testable import DitKitCore

final class ReportNamingTests: XCTestCase {

    func testTimestampFormatHasUnderscoreBeforeMilliseconds() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let date = f.date(from: "20261120_105208_123")!
        let stamp = ReportNaming.timestamp(date)
        XCTAssertEqual(stamp, "20261120_105208_123")
        // 秒(6位)与毫秒(3位)之间有下划线，而不是连在一起的 9 位。
        XCTAssertEqual(stamp.filter { $0 == "_" }.count, 2)
    }

    func testFileNamePutsTimestampFirst() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let date = f.date(from: "20261120_105208_123")!
        let name = ReportNaming.fileName(filePrefix: "DitKit_传输报告_复制_xxh128", ext: "mhl", at: date)
        XCTAssertEqual(name, "20261120_105208_123_DitKit_传输报告_复制_xxh128.mhl")
        XCTAssertTrue(name.hasPrefix("20261120"))
    }

    func testStripTimestampNewFormat() {
        let core = ReportNaming.stripTimestamp("20261120_105208_123_DitKit_传输报告.mhl")
        XCTAssertEqual(core, "DitKit_传输报告.mhl")
    }

    func testStripTimestampRejectsNonReportNames() {
        XCTAssertNil(ReportNaming.stripTimestamp("DitKit_传输报告_20261120_105208123.mhl"))
        XCTAssertNil(ReportNaming.stripTimestamp("a.txt"))
    }

    func testCleanPreviousReportsRemovesOnlyNewFormat() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("DitKitClean_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let prefix = "DitKit_传输报告_复制_xxh128"
        let newOld = dir.appendingPathComponent("20261101_000000_000_\(prefix).mhl")
        let newPdf = dir.appendingPathComponent("20261102_000000_000_\(prefix).pdf")
        let legacy = dir.appendingPathComponent("\(prefix)_20261103_000000000.mhl")
        let other = dir.appendingPathComponent("20261104_000000_000_DitKit_重命名报告.mhl")
        for url in [newOld, newPdf, legacy, other] {
            try Data("x".utf8).write(to: url)
        }

        let kept = dir.appendingPathComponent("20261120_105208_123_\(prefix).mhl")
        try Data("new".utf8).write(to: kept)
        MHLReport.cleanPreviousReports(directory: dir, filePrefix: prefix, except: kept)

        let remaining = Set(try fm.contentsOfDirectory(atPath: dir.path))
        XCTAssertTrue(remaining.contains(kept.lastPathComponent), "刚写入的新报告不能被清理")
        XCTAssertFalse(remaining.contains(newOld.lastPathComponent), "同前缀旧格式报告应被清理")
        XCTAssertFalse(remaining.contains(newPdf.lastPathComponent), "同前缀旧格式 PDF 应被清理")
        XCTAssertTrue(remaining.contains(legacy.lastPathComponent), "前缀在前的旧命名不再识别，应保留")
        XCTAssertTrue(remaining.contains(other.lastPathComponent), "不同前缀的报告不能被清理")
    }
}
