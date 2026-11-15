import XCTest
import Foundation
@testable import DitKitCore

final class TransferTests: XCTestCase {

    // MARK: - xxHash128 官方测试向量（与 `xxhsum -H2` 逐字节一致）

    func testXXH128Empty() async throws {
        let url = try makeFile(bytes: [])
        let (hash, size) = try await FileHasher.hash(fileAt: url, algorithm: .xxHash128)
        XCTAssertEqual(size, 0)
        XCTAssertEqual(hash, "99aa06d3014798d86001c324468d497f")
    }

    func testXXH128OneZeroByte() async throws {
        let url = try makeFile(bytes: [0x00])
        let (hash, size) = try await FileHasher.hash(fileAt: url, algorithm: .xxHash128)
        XCTAssertEqual(size, 1)
        XCTAssertEqual(hash, "a6cd5e9392000f6ac44bdff4074eecdb")
    }

    func testXXH128OneKilobyteZeros() async throws {
        let url = try makeFile(bytes: [UInt8](repeating: 0, count: 1024))
        let (hash, size) = try await FileHasher.hash(fileAt: url, algorithm: .xxHash128)
        XCTAssertEqual(size, 1024)
        XCTAssertEqual(hash, "0717191e67688313de5f15ab6daf7941")
    }

    func testXXH128TenMiBZeros() async throws {
        let url = try makeFile(bytes: [UInt8](repeating: 0, count: 10 * 1024 * 1024))
        let (hash, size) = try await FileHasher.hash(fileAt: url, algorithm: .xxHash128)
        XCTAssertEqual(size, Int64(10 * 1024 * 1024))
        XCTAssertEqual(hash, "c8a31a1122549fd37f74f91cf4508e33")
    }

    // MARK: - MD5 参考向量

    func testMD5Empty() async throws {
        let url = try makeFile(bytes: [])
        let (hash, _) = try await FileHasher.hash(fileAt: url, algorithm: .md5)
        XCTAssertEqual(hash, "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testMD5ABC() async throws {
        let url = try makeFile(bytes: Array("abc".utf8))
        let (hash, _) = try await FileHasher.hash(fileAt: url, algorithm: .md5)
        XCTAssertEqual(hash, "900150983cd24fb0d6963f7d28e17f72")
    }

    // MARK: - 复制模式往返 + ASC MHL 清单

    func testCopyModeRoundTripAndMHL() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitTransferTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 源：一个文件 + 一个文件夹（多文件夹整体保留规则用两个文件夹验证）。
        let src = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let f1 = src.appendingPathComponent("a.txt")
        try "hello".write(to: f1, atomically: true, encoding: .utf8)

        let dirA = src.appendingPathComponent("dirA")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try "x".write(to: dirA.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)

        let dirB = src.appendingPathComponent("dirB")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try "y".write(to: dirB.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)

        let target = tmp.appendingPathComponent("target")
        let config = TransferConfig(
            mode: .copy, algorithm: .xxHash128,
            sources: [f1, dirA, dirB],
            targets: [target]
        )
        let result = await TransferEngine.execute(config: config, onProgress: { _ in })
        XCTAssertNil(result.errorMessage, result.errorMessage ?? "")
        // a.txt 复制；dirA、dirB 作为多文件夹整体保留。
        XCTAssertEqual(result.copied, 3, "应为：a.txt、dirA/x.txt、dirB/y.txt")
        XCTAssertEqual(result.verifiedOK, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("dirA/x.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("dirB/y.txt").path))
        XCTAssertEqual(result.reportURLs.count, 2, "每个目标根一组报告：.mhl + .pdf")
        let reportURL = result.reportURLs[0]
        XCTAssertTrue(reportURL.pathExtension == "mhl")
        for url in result.reportURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let mhl = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(mhl.contains("<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">"))
        XCTAssertTrue(mhl.contains("<process>transfer</process>"))
        XCTAssertTrue(mhl.contains("<xxh128>"))
        XCTAssertTrue(mhl.contains("<path"))
        // PDF 报告存在且为合法 PDF 文件头。
        let pdfURL = reportURL.deletingPathExtension().appendingPathExtension("pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        let pdfHeader = try Data(contentsOf: pdfURL).prefix(5)
        XCTAssertEqual(String(data: pdfHeader, encoding: .ascii), "%PDF-")

        // 第二次传输：目标已存在 → 哈希校验一致后跳过，跳过记录必须带哈希；
        // 旧报告被替换为最新一组（reportURLs 总数仍为 2）。
        let second = await TransferEngine.execute(config: config, onProgress: { _ in })
        XCTAssertNil(second.errorMessage, second.errorMessage ?? "")
        XCTAssertEqual(second.copied, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.skipped, 3)
        XCTAssertEqual(second.reportURLs.count, 2)
        for record in second.records where record.action == .skipped {
            XCTAssertFalse(record.sourceHash.isEmpty, "跳过记录应带源哈希")
            XCTAssertFalse(record.targetHash.isEmpty, "跳过记录应带目标哈希")
            XCTAssertEqual(record.sourceHash, record.targetHash, "哈希一致才允许跳过")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "旧 MHL 应被新一轮报告替换")
    }

    // MARK: - 同步模式（多目标，多删少补）+ ASC MHL 清单

    func testSyncModeMultiTargetAndMHL() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitSyncTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 源目录：a.txt + sub/b.txt。
        let src = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: src.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        // 目标 1：预置多余文件 stale.txt 与多余目录 extra/junk.txt（验证「多删」）。
        let t1 = tmp.appendingPathComponent("t1")
        try FileManager.default.createDirectory(at: t1.appendingPathComponent("extra"), withIntermediateDirectories: true)
        try "old".write(to: t1.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: t1.appendingPathComponent("extra/junk.txt"), atomically: true, encoding: .utf8)

        // 目标 2：空目录（验证「少补」）。
        let t2 = tmp.appendingPathComponent("t2")
        try FileManager.default.createDirectory(at: t2, withIntermediateDirectories: true)

        let config = TransferConfig(
            mode: .sync, algorithm: .xxHash128,
            sources: [src],
            targets: [t1, t2]
        )
        let result = await TransferEngine.execute(config: config, onProgress: { _ in })
        XCTAssertNil(result.errorMessage, result.errorMessage ?? "")

        let fm = FileManager.default
        // 两个目标都应与源完全对齐。
        for t in [t1, t2] {
            XCTAssertTrue(fm.fileExists(atPath: t.appendingPathComponent("a.txt").path))
            XCTAssertTrue(fm.fileExists(atPath: t.appendingPathComponent("sub/b.txt").path))
        }
        // 目标 1 的多余项应被删除。
        XCTAssertFalse(fm.fileExists(atPath: t1.appendingPathComponent("stale.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: t1.appendingPathComponent("extra").path))
        // 统计：每个目标复制 2 个文件 → copied=4；多删 stale.txt + extra 目录 → deleted=2。
        XCTAssertEqual(result.copied, 4)
        XCTAssertEqual(result.deleted, 2)
        XCTAssertEqual(result.verifiedOK, 4)
        // 每个目标根各一组报告：ASC MHL 清单 + PDF 明细表。
        XCTAssertEqual(result.reportURLs.count, 4)
        let mhlCount = result.reportURLs.filter { $0.pathExtension == "mhl" }.count
        let pdfCount = result.reportURLs.filter { $0.pathExtension == "pdf" }.count
        XCTAssertEqual(mhlCount, 2)
        XCTAssertEqual(pdfCount, 2)
        for url in result.reportURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            if url.pathExtension == "pdf" {
                let header = try Data(contentsOf: url).prefix(5)
                XCTAssertEqual(String(data: header, encoding: .ascii), "%PDF-")
            }
        }

        // MHL 完整明细段：本轮的复制、删除都留档，元信息与汇总和 PDF 同源。
        let t1MHL = try XCTUnwrap(result.reportURLs.first {
            $0.pathExtension == "mhl" && $0.deletingLastPathComponent().lastPathComponent == "t1"
        })
        let firstXML = try String(contentsOf: t1MHL, encoding: .utf8)
        XCTAssertTrue(firstXML.contains("<dk:report xmlns:dk=\"urn:ditkit:report:v1\">"))
        XCTAssertTrue(firstXML.contains("action=\"复制\""))
        XCTAssertTrue(firstXML.contains("action=\"删除\""))
        XCTAssertTrue(firstXML.contains("stale.txt"))
        XCTAssertTrue(firstXML.contains("<dk:meta>"))
        XCTAssertTrue(firstXML.contains("模式：同步"))
        XCTAssertTrue(firstXML.contains("<dk:summary>"))
        let firstHashes = firstXML.components(separatedBy: "</hashes>").first ?? ""
        XCTAssertFalse(firstHashes.contains("stale.txt"), "已删除文件不应进标准哈希清单")

        // 第二次同步：全部跳过，且跳过记录带哈希校验（源=目标才允许跳过）。
        let second = await TransferEngine.execute(config: config, onProgress: { _ in })
        XCTAssertNil(second.errorMessage, second.errorMessage ?? "")
        XCTAssertEqual(second.copied, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.skipped, 4)
        XCTAssertEqual(second.deleted, 0)
        for record in second.records where record.action == .skipped {
            XCTAssertFalse(record.sourceHash.isEmpty, "跳过记录应带源哈希")
            XCTAssertFalse(record.targetHash.isEmpty, "跳过记录应带目标哈希")
            XCTAssertEqual(record.sourceHash, record.targetHash, "哈希一致才允许跳过")
        }
        // 跳过项既在完整明细段，也进入标准哈希清单（文件存在且哈希有效）。
        let secondMHLs = second.reportURLs.filter { $0.pathExtension == "mhl" }
        XCTAssertEqual(secondMHLs.count, 2)
        for url in secondMHLs {
            let xml = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(xml.contains("action=\"跳过\""))
            let hashes = xml.components(separatedBy: "</hashes>").first ?? ""
            XCTAssertTrue(hashes.contains("a.txt"))
        }
    }

    // MARK: - 暂停 / 停止（文件边界 + 部分报告）

    func testCopyStopWritesPartialReport() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitCopyStopTest_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "a".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let target = tmp.appendingPathComponent("target")
        let config = TransferConfig(mode: .copy, algorithm: .xxHash128, sources: [src], targets: [target])
        let control = RunControl()
        let result = await TransferEngine.execute(config: config, onProgress: { p in
            if p.filesDone == 1 { control.stop() }
        }, control: control)
        XCTAssertNil(result.errorMessage, result.errorMessage ?? "")
        XCTAssertTrue(result.stopped)
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.reportURLs.count, 2, "停止后仍生成 MHL + PDF")
        let mhl = try XCTUnwrap(result.reportURLs.first { $0.pathExtension == "mhl" })
        let xml = try String(contentsOf: mhl, encoding: .utf8)
        XCTAssertEqual(xml.components(separatedBy: "<hash>").count - 1, 1, "部分清单只含已完成项")
        let pdf = mhl.deletingPathExtension().appendingPathExtension("pdf")
        XCTAssertTrue(fm.fileExists(atPath: pdf.path))
        let copiedNames = try fm.contentsOfDirectory(atPath: target.path).filter { !$0.hasPrefix("DitKit_") }
        XCTAssertEqual(copiedNames.count, 1, "停止后第二个文件不应被复制")
    }

    func testCopyPauseAndResumeCompletes() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitCopyPauseTest_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "a".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let target = tmp.appendingPathComponent("target")
        let config = TransferConfig(mode: .copy, algorithm: .xxHash128, sources: [src], targets: [target])
        let control = RunControl()
        let resumeTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            control.resume()
        }
        let result = await TransferEngine.execute(config: config, onProgress: { p in
            if p.filesDone == 1 { control.pause() }
        }, control: control)
        await resumeTask.value
        XCTAssertFalse(result.stopped)
        XCTAssertEqual(result.copied, 2, "恢复后应继续把剩余文件传完")
    }

    func testSyncStopSkipsCleanup() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitSyncStopTest_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let target = tmp.appendingPathComponent("target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        let config = TransferConfig(mode: .sync, algorithm: .xxHash128, sources: [src], targets: [target])
        let control = RunControl()
        let result = await TransferEngine.execute(config: config, onProgress: { p in
            if p.filesDone == 1 { control.stop() }
        }, control: control)
        XCTAssertTrue(result.stopped)
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.deleted, 0, "停止后不应再进入清理多余项阶段")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("stale.txt").path))
    }

    // MARK: - 工具

    private func makeFile(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitHashTest_\(UUID().uuidString).bin")
        if bytes.isEmpty {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        } else {
            try Data(bytes).write(to: url)
        }
        return url
    }
}
