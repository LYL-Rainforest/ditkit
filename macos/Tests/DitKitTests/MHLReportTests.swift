import XCTest
import Foundation
@testable import DitKitCore

final class MHLReportTests: XCTestCase {

    // MARK: - MHLReport 基础（ASC MHL v2.0 XML 结构）

    func testMHLReportXMLStructure() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitMHLTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let entries: [MHLReport.Entry] = [
            .init(path: "dirA/x.txt", size: 123, lastModificationDate: Date(timeIntervalSince1970: 0),
                  algorithm: "xxh128", hashValue: "0717191e67688313de5f15ab6daf7941"),
            .init(path: "new name & <file>.jpg", size: 456, lastModificationDate: nil,
                  algorithm: "md5", hashValue: "d41d8cd98f00b204e9800998ecf8427e",
                  previousPath: "old name.jpg"),
        ]
        let url = try MHLReport.write(
            entries: entries, process: "transfer", directory: tmp,
            filePrefix: "DitKit_测试", startedAt: Date(), finishedAt: Date()
        )
        XCTAssertTrue(url.pathExtension == "mhl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let xml = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">"))
        XCTAssertTrue(xml.contains("<creatorinfo>"))
        XCTAssertTrue(xml.contains("<tool version=\"0.2.0\">DitKit</tool>"))
        XCTAssertTrue(xml.contains("<process>transfer</process>"))
        XCTAssertTrue(xml.contains("<path size=\"123\""))
        XCTAssertTrue(xml.contains("<xxh128>0717191e67688313de5f15ab6daf7941</xxh128>"))
        XCTAssertTrue(xml.contains("<md5>d41d8cd98f00b204e9800998ecf8427e</md5>"))
        XCTAssertTrue(xml.contains("<previousPath>old name.jpg</previousPath>"))
        // XML 转义
        XCTAssertTrue(xml.contains("new name &amp; &lt;file&gt;.jpg"))
        // lastmodificationdate 属性为 ISO8601 dateTime
        XCTAssertTrue(xml.contains("lastmodificationdate=\"1970-01-01T"))
        XCTAssertTrue(xml.contains("</hashlist>"))
    }

    // MARK: - 完整明细段（所有操作，而不只是复制）

    func testMHLReportWritesFullDetailSegment() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitMHLDetailTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let detail = MHLReportDetail(
            meta: ["模式：同步", "目标目录：/tmp/a & b"],
            summary: ["复制 1 · 跳过 1 · 删除 1 · 失败 0"],
            records: [
                .init(action: "复制", path: "a.txt", size: 3, algorithm: "xxh128",
                      sourceHash: "aa", targetHash: "aa", verify: "一致"),
                .init(action: "跳过", path: "b.txt", size: 4, algorithm: "xxh128",
                      sourceHash: "bb", targetHash: "bb", verify: "一致"),
                .init(action: "删除", path: "old & <x>.txt", size: 9, algorithm: "xxh128",
                      verify: "—", note: "目标多余文件，已删除"),
            ]
        )
        let url = try MHLReport.write(
            entries: [
                .init(path: "a.txt", size: 3, algorithm: "xxh128", hashValue: "aa"),
                .init(path: "b.txt", size: 4, algorithm: "xxh128", hashValue: "bb"),
            ],
            process: "transfer", directory: tmp, filePrefix: "DitKit_明细测试",
            startedAt: Date(), finishedAt: Date(), detail: detail
        )
        let xml = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(xml.contains("<dk:report xmlns:dk=\"urn:ditkit:report:v1\">"))
        XCTAssertTrue(xml.contains("<dk:line>模式：同步</dk:line>"))
        XCTAssertTrue(xml.contains("目标目录：/tmp/a &amp; b"))
        XCTAssertTrue(xml.contains("<dk:line>复制 1 · 跳过 1 · 删除 1 · 失败 0</dk:line>"))
        XCTAssertTrue(xml.contains("action=\"复制\""))
        XCTAssertTrue(xml.contains("action=\"跳过\""))
        XCTAssertTrue(xml.contains("action=\"删除\""))
        XCTAssertTrue(xml.contains("<dk:verify>—</dk:verify>"))
        XCTAssertTrue(xml.contains("old &amp; &lt;x&gt;.txt"))
        XCTAssertEqual(xml.components(separatedBy: "<dk:record ").count - 1, 3)
        // 删除项没有有效目标文件，只能留在明细段，不进标准哈希清单。
        let hashesBlock = xml.components(separatedBy: "</hashes>").first ?? ""
        XCTAssertFalse(hashesBlock.contains("old"))
        XCTAssertTrue(xml.hasSuffix("</hashlist>\n"))

        // 读回：明细段可被解析，元信息/操作/备注都不丢。
        let document = try MHLReader.read(url)
        XCTAssertEqual(document.detail?.meta.first, "模式：同步")
        XCTAssertEqual(document.detail?.summary.count, 1)
        XCTAssertEqual(document.detail?.records.count, 3)
        XCTAssertEqual(document.detail?.records[2].action, "删除")
        XCTAssertEqual(document.detail?.records[2].path, "old & <x>.txt")
        XCTAssertEqual(document.detail?.records[2].note, "目标多余文件，已删除")
        XCTAssertEqual(document.entries.count, 2, "标准哈希条目不受明细段影响")
    }

    // MARK: - RenameMHL（in-place 流程，previousPath 记录原文件名）

    func testRenameMHLPerDirectoryAndSkipAllUnchanged() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitRenameMHLTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let dirA = tmp.appendingPathComponent("dirA")
        let dirB = tmp.appendingPathComponent("dirB")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        // dirA：一个已重命名（新文件真实存在）、一个无需改动（新文件真实存在）、一个失败（文件不存在）。
        try Data([0x61]).write(to: dirA.appendingPathComponent("20261110_120000_123.jpg"))
        try Data([0x62]).write(to: dirA.appendingPathComponent("20261110_120000_123-1.jpg"))
        // dirB：全部无需改动。
        try Data([0x63]).write(to: dirB.appendingPathComponent("c.jpg"))

        func item(_ dir: URL, original: String, proposed: String, state: RenameItemState) -> RenameItem {
            var it = RenameItem(
                url: dir.appendingPathComponent(original),
                capture: nil,
                captureDateText: "20261110_120000 · 文件时间",
                millisecond: "123",
                millisecondSource: .exif,
                proposedName: proposed
            )
            it.state = state
            return it
        }

        let items = [
            item(dirA, original: "old1.jpg", proposed: "20261110_120000_123.jpg", state: .renamed),
            item(dirA, original: "old2.jpg", proposed: "20261110_120000_123-1.jpg", state: .unchanged),
            item(dirA, original: "old3.jpg", proposed: "old3.jpg", state: .failed("目标文件已存在")),
            item(dirB, original: "c.jpg", proposed: "c.jpg", state: .unchanged),
        ]

        let urls = try await RenameMHL.write(items: items, startedAt: Date(), finishedAt: Date())
        // dirA 有重命名 → 写一组（.mhl + .pdf）；dirB 全部无需改动 → 不写。
        XCTAssertEqual(urls.count, 2)
        let mhlURL = urls.first { $0.pathExtension == "mhl" }
        let pdfURL = urls.first { $0.pathExtension == "pdf" }
        XCTAssertNotNil(mhlURL)
        XCTAssertNotNil(pdfURL)
        XCTAssertEqual(mhlURL!.deletingLastPathComponent().standardizedFileURL.path,
                       dirA.standardizedFileURL.path)
        XCTAssertEqual(pdfURL!.deletingLastPathComponent().standardizedFileURL.path,
                       dirA.standardizedFileURL.path)

        let xml = try String(contentsOf: mhlURL!, encoding: .utf8)
        XCTAssertTrue(xml.contains("<process>in-place</process>"))
        XCTAssertTrue(xml.contains("<xxh128>"))
        XCTAssertTrue(xml.contains("<previousPath>old1.jpg</previousPath>"))
        // 失败项（old3）不进标准 <hashes>，但要完整留在明细段里。
        let hashesBlock = xml.components(separatedBy: "</hashes>").first ?? ""
        XCTAssertFalse(hashesBlock.contains("old3"))
        XCTAssertTrue(xml.contains("<dk:report xmlns:dk=\"urn:ditkit:report:v1\">"))
        XCTAssertTrue(xml.contains("action=\"失败\""))
        XCTAssertTrue(xml.contains("old3.jpg"))
        XCTAssertTrue(xml.contains("目标文件已存在"))
        // 哈希值为 32 位十六进制（XXH128：128 bit = 16 字节 = 32 hex，大端）。
        if let start = xml.range(of: "<xxh128>")?.upperBound,
           let end = xml.range(of: "</xxh128>")?.lowerBound {
            let hash = String(xml[start..<end])
            XCTAssertEqual(hash.count, 32)
            XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
        } else {
            XCTFail("缺少 xxh128 元素")
        }

        // PDF：合法文件头，且包含失败项明细。
        let pdfData = try Data(contentsOf: pdfURL!)
        XCTAssertEqual(String(data: pdfData.prefix(5), encoding: .ascii), "%PDF-")
        XCTAssertGreaterThan(pdfData.count, 500)
    }

    // MARK: - 停止后的重命名部分报告

    func testStoppedRenameReportOnlyContainsCompleted() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DitKitStoppedRenameReport_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("dir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x61]).write(to: dir.appendingPathComponent("20261110_120000_123.jpg"))

        func item(_ original: String, _ proposed: String, _ state: RenameItemState) -> RenameItem {
            var it = RenameItem(
                url: dir.appendingPathComponent(original),
                capture: nil,
                captureDateText: "20261110_120000 · 文件时间",
                millisecond: "123",
                millisecondSource: .exif,
                proposedName: proposed
            )
            it.state = state
            return it
        }
        let items = [
            item("old1.jpg", "20261110_120000_123.jpg", .renamed),
            item("old2.jpg", "20261110_120000_999.jpg", .pending),
        ]
        let urls = try await RenameMHL.write(
            items: items, startedAt: Date(), finishedAt: Date(),
            onlyCompleted: true, statusNote: "已停止（部分报告）", allowEmpty: true
        )
        XCTAssertEqual(urls.count, 2)
        let mhl = try XCTUnwrap(urls.first { $0.pathExtension == "mhl" })
        let xml = try String(contentsOf: mhl, encoding: .utf8)
        XCTAssertEqual(xml.components(separatedBy: "<hash>").count - 1, 1, "清单只含已完成项")
        XCTAssertTrue(xml.contains("20261110_120000_123.jpg"))
        XCTAssertFalse(xml.contains("20261110_120000_999.jpg"), "未处理项不应进清单")
        XCTAssertTrue(xml.contains("<previousPath>old1.jpg</previousPath>"))
        let pdf = try XCTUnwrap(urls.first { $0.pathExtension == "pdf" })
        XCTAssertEqual(String(data: try Data(contentsOf: pdf).prefix(5), encoding: .ascii), "%PDF-")
    }

    // MARK: - PDFReport（纯生成器）

    func testPDFReportGeneratorProducesValidPDF() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitPDFTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let url = tmp.appendingPathComponent("DitKit_测试报告.pdf")
        try PDFReport.write(
            title: "DitKit 测试报告",
            meta: ["模式：复制", "校验算法：xxHash128", "目标目录：\(tmp.path)"],
            summary: ["复制 2 · 更新 0 · 跳过 1 · 删除 0 · 失败 0 · 校验通过 2"],
            columns: [
                .init(name: "操作", width: 48),
                .init(name: "相对路径", width: 0),
                .init(name: "哈希", width: 138, monospace: true),
            ],
            rows: [
                .init(["复制", "dirA/x.txt", "0717191e67688313de5f15ab6daf7941"], color: .good),
                .init(["跳过", "很长很长的相对路径目录名/很长很长的子目录名/另一个子目录名/文件名.jpg", "—"], color: .muted),
                .init(["复制", "失败文件路径<特殊>&字符.txt", "d41d8cd98f00b204e9800998ecf8427e"], color: .bad),
            ],
            to: url
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
        XCTAssertTrue(data.count > 500)
    }
}
