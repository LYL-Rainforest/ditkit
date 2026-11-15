import XCTest
import Foundation
@testable import DitKitCore

final class MHLReaderTests: XCTestCase {

    func testReadAndVerify() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitMHLReaderTest_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // a.txt：内容不变 → 校验一致。
        let a = tmp.appendingPathComponent("a.txt")
        try "hello".write(to: a, atomically: true, encoding: .utf8)
        let (aHash, aSize) = try await FileHasher.hash(fileAt: a, algorithm: .xxHash128)

        // b.txt：生成清单后篡改内容 → 校验不一致。
        let b = tmp.appendingPathComponent("b.txt")
        try "world".write(to: b, atomically: true, encoding: .utf8)
        let (bHash, _) = try await FileHasher.hash(fileAt: b, algorithm: .md5)

        let url = try MHLReport.write(
            entries: [
                .init(path: "a.txt", size: aSize, lastModificationDate: Date(timeIntervalSince1970: 0),
                      algorithm: "xxh128", hashValue: aHash, previousPath: "old name & <a>.txt"),
                .init(path: "b.txt", size: 5, algorithm: "md5", hashValue: bHash),
                .init(path: "c.txt", algorithm: "sha1", hashValue: "abc123"),
                .init(path: "missing.txt", algorithm: "xxh128", hashValue: "00"),
            ],
            process: "transfer", directory: tmp, filePrefix: "DitKit_查看器测试",
            startedAt: Date(), finishedAt: Date()
        )
        try "WORLD".write(to: b, atomically: true, encoding: .utf8)

        let document = try MHLReader.read(url)
        XCTAssertEqual(document.version, "2.0")
        XCTAssertEqual(document.process, "transfer")
        XCTAssertEqual(document.toolName, "DitKit")
        XCTAssertEqual(document.entries.count, 4)
        XCTAssertEqual(document.entries[0].path, "a.txt")
        XCTAssertEqual(document.entries[0].size, aSize)
        XCTAssertEqual(document.entries[0].algorithm, "xxh128")
        XCTAssertEqual(document.entries[0].hashValue, aHash)
        XCTAssertEqual(document.entries[0].previousPath, "old name & <a>.txt")
        XCTAssertEqual(document.entries[1].algorithm, "md5")
        XCTAssertNil(document.entries[1].previousPath)

        let results = await MHLVerifier.verify(document)
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results[0].status, .matched)
        XCTAssertEqual(results[1].status, .mismatch)
        XCTAssertNotNil(results[1].actualHash)
        XCTAssertEqual(results[2].status, .unsupported)
        XCTAssertEqual(results[3].status, .missing)
    }

    func testVerifyStopKeepsRemainingUnchecked() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitVerifyStopTest_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        var entries: [MHLReport.Entry] = []
        for name in ["a.txt", "b.txt", "c.txt"] {
            let file = tmp.appendingPathComponent(name)
            try name.write(to: file, atomically: true, encoding: .utf8)
            let (hash, size) = try await FileHasher.hash(fileAt: file, algorithm: .xxHash128)
            entries.append(.init(path: name, size: size, algorithm: "xxh128", hashValue: hash))
        }
        let url = try MHLReport.write(
            entries: entries, process: "transfer", directory: tmp,
            filePrefix: "DitKit_校验停止测试", startedAt: Date(), finishedAt: Date()
        )
        let document = try MHLReader.read(url)
        let control = RunControl()
        let outcome = await MHLVerifier.verifyControlled(
            document, control: control, onProgress: { done, _ in
                if done == 1 { control.stop() }
            }
        )
        XCTAssertTrue(outcome.stopped)
        XCTAssertEqual(outcome.rows.count, 3)
        XCTAssertEqual(outcome.rows[0].status, .matched)
        XCTAssertEqual(outcome.rows[1].status, .unchecked, "未处理条目保持未校验")
        XCTAssertEqual(outcome.rows[2].status, .unchecked)
    }

    func testFullDetailRecordsDisplayedButNotVerified() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitMHLDetailRead_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let (hash, size) = try await FileHasher.hash(fileAt: file, algorithm: .xxHash128)

        let url = try MHLReport.write(
            entries: [.init(path: "a.txt", size: size, algorithm: "xxh128", hashValue: hash)],
            process: "transfer", directory: tmp, filePrefix: "DitKit_完整明细读取",
            startedAt: Date(), finishedAt: Date(),
            detail: MHLReportDetail(
                meta: ["模式：同步"],
                summary: ["复制 1 · 删除 1 · 失败 1"],
                records: [
                    .init(action: "复制", path: "a.txt", size: size, algorithm: "xxh128",
                          sourceHash: hash, targetHash: hash, verify: "一致"),
                    .init(action: "删除", path: "gone.txt", verify: "—", note: "目标多余文件，已删除"),
                    .init(action: "失败", path: "bad.txt", verify: "不一致", note: "权限不足"),
                ]
            )
        )
        let document = try MHLReader.read(url)
        XCTAssertEqual(document.detail?.meta, ["模式：同步"])
        XCTAssertEqual(document.detail?.summary, ["复制 1 · 删除 1 · 失败 1"])
        XCTAssertEqual(document.detail?.records.count, 3)
        XCTAssertEqual(document.detail?.records[2].note, "权限不足")

        let initial = MHLVerifier.initialRows(document)
        XCTAssertEqual(initial.count, 3, "查看器按全部操作记录显示，而不是只看哈希条目")
        XCTAssertEqual(initial[0].action, "复制")
        XCTAssertTrue(initial[0].verifiable)
        XCTAssertEqual(initial[1].status, .notApplicable)
        XCTAssertFalse(initial[1].verifiable)
        XCTAssertEqual(initial[2].status, .notApplicable)
        XCTAssertFalse(initial[2].verifiable)

        let rows = await MHLVerifier.verify(document)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].status, .matched)
        XCTAssertEqual(rows[1].status, .notApplicable, "删除行不参与哈希校验")
        XCTAssertEqual(rows[2].status, .notApplicable, "失败行不参与哈希校验")
        XCTAssertEqual(rows[1].detail, "目标多余文件，已删除")
    }

    func testVerifySelectedOnlyChecksGivenRows() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitVerifySelectedTest_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        var entries: [MHLReport.Entry] = []
        var records: [MHLReportDetail.Record] = []
        for (index, name) in ["a.txt", "b.txt"].enumerated() {
            let file = tmp.appendingPathComponent(name)
            try name.write(to: file, atomically: true, encoding: .utf8)
            let (hash, size) = try await FileHasher.hash(fileAt: file, algorithm: .xxHash128)
            entries.append(.init(path: name, size: size, algorithm: "xxh128", hashValue: hash))
            records.append(.init(action: index == 0 ? "复制" : "跳过", path: name,
                                 size: size, algorithm: "xxh128",
                                 sourceHash: hash, targetHash: hash, verify: "一致"))
        }
        let url = try MHLReport.write(
            entries: entries, process: "transfer", directory: tmp,
            filePrefix: "DitKit_筛选校验测试", startedAt: Date(), finishedAt: Date(),
            detail: MHLReportDetail(meta: [], summary: [], records: records)
        )
        let document = try MHLReader.read(url)
        let initial = MHLVerifier.initialRows(document)
        XCTAssertEqual(initial.count, 2)

        // 只校验「跳过」那一行：返回 1 行且已校验，另一行不在结果里。
        let selected = initial.filter { $0.action == "跳过" }
        let outcome = await MHLVerifier.verifySelected(selected, in: document, control: nil)
        XCTAssertFalse(outcome.stopped)
        XCTAssertEqual(outcome.rows.count, 1)
        XCTAssertEqual(outcome.rows[0].entry.path, "b.txt")
        XCTAssertEqual(outcome.rows[0].status, .matched)
        XCTAssertEqual(outcome.rows[0].action, "跳过")
    }

    func testRejectNonHashlistXML() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitMHLBad_\(UUID().uuidString).mhl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "<foo><bar/></foo>".write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MHLReader.read(tmp)) { error in
            XCTAssertTrue(error is MHLReaderError)
        }
    }

    func testAlgorithmFromMHLTag() {
        XCTAssertEqual(HashAlgorithm(mhlTag: "xxh128"), .xxHash128)
        XCTAssertEqual(HashAlgorithm(mhlTag: "MD5"), .md5)
        XCTAssertNil(HashAlgorithm(mhlTag: "sha1"))
    }
}
