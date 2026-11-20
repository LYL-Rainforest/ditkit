import XCTest
import Foundation
@testable import DitKitCore

final class ReportPlacementTests: XCTestCase {

    func testDefaultWritesAlongsideOnly() {
        let p = ReportPlacement.default
        XCTAssertTrue(p.writeAlongside)
        XCTAssertNil(p.customURL)
        XCTAssertTrue(p.producesReports)
        let natural = URL(fileURLWithPath: "/tmp/target")
        let outs = p.outputs(natural: natural, basePrefix: "DitKit_传输报告")
        XCTAssertEqual(outs.count, 1)
        XCTAssertEqual(outs[0].directory.path, "/tmp/target")
        XCTAssertEqual(outs[0].filePrefix, "DitKit_传输报告")
    }

    func testNothingSelectedProducesNoReports() {
        let p = ReportPlacement(writeAlongside: false, customDirectory: "")
        XCTAssertFalse(p.producesReports)
        XCTAssertNil(p.customURL)
        let outs = p.outputs(natural: URL(fileURLWithPath: "/tmp/target"), basePrefix: "P")
        XCTAssertTrue(outs.isEmpty)
    }

    func testWhitespaceCustomPathCountsAsNotSelected() {
        let p = ReportPlacement(writeAlongside: false, customDirectory: "   \n  ")
        XCTAssertNil(p.customURL)
        XCTAssertFalse(p.producesReports)
    }

    func testBothSelectedWritesTwoOutputsWithDistinctPrefixes() {
        let p = ReportPlacement(writeAlongside: true, customDirectory: "/tmp/reports")
        let natural = URL(fileURLWithPath: "/tmp/target")
        let outs = p.outputs(natural: natural, basePrefix: "DitKit_传输报告_复制_xxh128")
        XCTAssertEqual(outs.count, 2)
        XCTAssertEqual(outs[0].directory.path, "/tmp/target")
        XCTAssertEqual(outs[0].filePrefix, "DitKit_传输报告_复制_xxh128")
        XCTAssertEqual(outs[1].directory.path, "/tmp/reports")
        XCTAssertTrue(outs[1].filePrefix.hasPrefix("DitKit_传输报告_复制_xxh128__"),
                      "自定义目录的前缀必须带来源标识: \(outs[1].filePrefix)")
        XCTAssertNotEqual(outs[0].filePrefix, outs[1].filePrefix)
    }

    func testCustomOnly() {
        let p = ReportPlacement(writeAlongside: false, customDirectory: "/tmp/reports")
        let outs = p.outputs(natural: URL(fileURLWithPath: "/tmp/target"), basePrefix: "P")
        XCTAssertEqual(outs.count, 1)
        XCTAssertEqual(outs[0].directory.path, "/tmp/reports")
    }

    func testTildeExpansion() {
        let p = ReportPlacement(writeAlongside: false, customDirectory: "~/reports")
        let url = p.customURL
        XCTAssertNotNil(url)
        XCTAssertFalse(url!.path.contains("~"))
        XCTAssertTrue(url!.path.hasSuffix("/reports"))
    }

    func testCustomToggleIsIndependentOfPath() {
        // 勾选但路径为空：不生效（UI 勾选时会自动填默认路径，这里验证底层防御）。
        let checkedEmpty = ReportPlacement(writeAlongside: false, customDirectory: "", useCustomDirectory: true)
        XCTAssertTrue(checkedEmpty.useCustomDirectory)
        XCTAssertNil(checkedEmpty.customURL)
        XCTAssertFalse(checkedEmpty.producesReports)

        // 有路径但未勾选：不生效。
        let uncheckedPath = ReportPlacement(writeAlongside: false, customDirectory: "/tmp/reports",
                                            useCustomDirectory: false)
        XCTAssertFalse(uncheckedPath.useCustomDirectory)
        XCTAssertNil(uncheckedPath.customURL)
        XCTAssertFalse(uncheckedPath.producesReports)

        // 勾选 + 有路径：生效。
        let both = ReportPlacement(writeAlongside: false, customDirectory: "/tmp/reports",
                                   useCustomDirectory: true)
        XCTAssertNotNil(both.customURL)
        XCTAssertTrue(both.producesReports)
    }

    func testLegacyConstructorInfersToggleFromPath() {
        // 旧调用只传路径：非空路径应自动视为勾选，保证既有测试与调用兼容。
        let legacy = ReportPlacement(writeAlongside: false, customDirectory: "/tmp/reports")
        XCTAssertTrue(legacy.useCustomDirectory)
        XCTAssertNotNil(legacy.customURL)

        let empty = ReportPlacement(writeAlongside: true, customDirectory: "")
        XCTAssertFalse(empty.useCustomDirectory)
    }

    func testSourceTokenStableAndDistinct() {
        let a = URL(fileURLWithPath: "/tmp/photo")
        let b = URL(fileURLWithPath: "/tmp/photo")
        XCTAssertEqual(ReportPlacement.sourceToken(for: a), ReportPlacement.sourceToken(for: b),
                       "同一路径跨构造必须得到相同标识")

        let other = URL(fileURLWithPath: "/other/photo")
        XCTAssertNotEqual(ReportPlacement.sourceToken(for: a), ReportPlacement.sourceToken(for: other),
                          "同名不同路径不能得到相同标识")
    }

    func testSourceTokenIsFilenameSafe() {
        let url = URL(fileURLWithPath: "/tmp/我的 照片/2026:11")
        let token = ReportPlacement.sourceToken(for: url)
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains(":"))
        XCTAssertFalse(token.contains(" "))
        XCTAssertTrue(token.contains("2026_11"))
    }

    func testDistinctSourcesGetDistinctCustomPrefixes() {
        let p = ReportPlacement(writeAlongside: false, customDirectory: "/tmp/reports")
        let one = p.outputs(natural: URL(fileURLWithPath: "/vol/a/target"), basePrefix: "P")
        let two = p.outputs(natural: URL(fileURLWithPath: "/vol/b/target"), basePrefix: "P")
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(two.count, 1)
        XCTAssertNotEqual(one[0].filePrefix, two[0].filePrefix,
                          "平铺到同一目录时，不同来源必须生成不同前缀，避免互相覆盖")
    }
}
