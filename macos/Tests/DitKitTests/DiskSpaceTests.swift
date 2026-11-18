import XCTest
import Foundation
@testable import DitKitCore

final class DiskSpaceTests: XCTestCase {
    func testTopEntriesAggregatesChildrenAndSkipsHiddenItems() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DitKitDiskSpace_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("dirA"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dirB"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: root.appendingPathComponent("dirA/a.bin"))
        try Data(repeating: 2, count: 2_000).write(to: root.appendingPathComponent("dirA/b.bin"))
        try Data(repeating: 3, count: 500).write(to: root.appendingPathComponent("dirB/c.bin"))
        try Data(repeating: 4, count: 9_000).write(to: root.appendingPathComponent(".hidden/secret.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("dirA"))

        let entries = DiskSpaceScanner.topEntries(in: root, limit: 10)
        XCTAssertEqual(entries.first?.name, "dirA", "两个文件的目录应排在单个文件目录之前")
        XCTAssertGreaterThanOrEqual(entries.first?.bytes ?? 0, 3_000)
        XCTAssertFalse(entries.contains { $0.name == ".hidden" }, "隐藏目录应跳过")
        XCTAssertFalse(entries.contains { $0.name == "link" }, "符号链接应跳过")
        XCTAssertEqual(entries.map(\.name).sorted(), ["dirA", "dirB"])
    }

    func testTopEntriesRespectsCancellation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DitKitDiskSpaceCancel_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: root.appendingPathComponent("a.bin"))

        let entries = DiskSpaceScanner.topEntries(in: root, limit: 10, isCancelled: { true })
        XCTAssertTrue(entries.isEmpty, "取消后不应返回扫描结果")
    }

    // MARK: - 按需目录树

    func testChildrenReadsOneLevelOnlyAndLeavesDirectorySizeUnmeasured() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DitKitTree_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("sub/inner"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 300).write(to: root.appendingPathComponent("sub/inner/deep.bin"))
        try Data(repeating: 2, count: 200).write(to: root.appendingPathComponent("top.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("sub"))

        let children = DiskSpaceScanner.children(of: root)
        XCTAssertEqual(children.map(\.name), ["sub", "top.bin"], "目录在前、符号链接与隐藏项跳过")
        XCTAssertTrue(children.first?.isDirectory == true)
        XCTAssertNil(children.first?.size, "目录大小应留到展开时统计，列目录本身不递归")
        XCTAssertGreaterThanOrEqual(children.last?.size ?? 0, 200, "文件给出自身磁盘占用（按块对齐，≥ 逻辑大小）")

        let deep = DiskSpaceScanner.children(of: root.appendingPathComponent("sub"))
        XCTAssertEqual(deep.map(\.name), ["inner"], "展开 sub 才读到它的下一层")
    }

    func testRecursiveSizeAggregatesWholeSubtree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DitKitTreeSize_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: root.appendingPathComponent("a/b/one.bin"))
        try Data(repeating: 2, count: 700).write(to: root.appendingPathComponent("a/two.bin"))
        try Data(repeating: 3, count: 900).write(to: root.appendingPathComponent(".hidden.bin"))

        let measured = DiskSpaceScanner.recursiveSize(of: root.appendingPathComponent("a"))
        XCTAssertGreaterThanOrEqual(measured, 1_700, "递归统计应累加所有层级文件，且跳过隐藏项")
    }

    func testRankedChildrenSortsBySizeAndLimitsTop() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DitKitRank_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        // 5 个子目录，写入不同大小（每个跨多个 4096 块，避免都被块对齐成同一大小）。
        for i in 1...5 {
            let dir = root.appendingPathComponent("dir\(i)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: UInt8(i), count: i * 100_000).write(to: dir.appendingPathComponent("f.bin"))
        }

        let all = DiskSpaceScanner.rankedChildren(in: root)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.map(\.name), ["dir5", "dir4", "dir3", "dir2", "dir1"], "按占用降序")
        XCTAssertTrue(all.allSatisfy { $0.size != nil }, "返回项都带已统计的大小")

        let top = DiskSpaceScanner.rankedChildren(in: root, limit: 4)
        XCTAssertEqual(top.map(\.name), ["dir5", "dir4", "dir3", "dir2"], "顶层截断前 4")
    }

    func testChildrenAndRecursiveSizeRespectCancellation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DitKitTreeCancel_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("a.bin"))

        XCTAssertTrue(DiskSpaceScanner.children(of: root, isCancelled: { true }).isEmpty)
        XCTAssertEqual(DiskSpaceScanner.recursiveSize(of: root, isCancelled: { true }), 0)
    }
}
