import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import DitKitCore

final class RenameTests: XCTestCase {
    // MARK: - 毫秒三位规则

    func testSubsecondTwoDigitsPadsZero() {
        let (ms, source) = RenameFormatter.millisecond(raw: "12")
        XCTAssertEqual(ms, "120")
        XCTAssertEqual(source, .exifPadded)
    }

    func testSubsecondOneDigitPadsTwoZeros() {
        let (ms, source) = RenameFormatter.millisecond(raw: "7")
        XCTAssertEqual(ms, "700")
        XCTAssertEqual(source, .exifPadded)
    }

    func testSubsecondMoreThanThreeDigitsTakesFirstThree() {
        let (ms, source) = RenameFormatter.millisecond(raw: "123456")
        XCTAssertEqual(ms, "123")
        XCTAssertEqual(source, .exif)
    }

    func testSubsecondExactlyThreeDigits() {
        let (ms, source) = RenameFormatter.millisecond(raw: "045")
        XCTAssertEqual(ms, "045")
        XCTAssertEqual(source, .exif)
    }

    func testMissingSubsecondUsesSystemMillisecond() {
        for raw in [nil, "", "abc"] {
            let (ms, source) = RenameFormatter.millisecond(raw: raw)
            XCTAssertEqual(ms.count, 3)
            XCTAssertTrue(ms.allSatisfy { $0.isNumber })
            XCTAssertEqual(source, .system)
        }
    }

    // MARK: - 文件名格式

    func testFileNameWithCustomSuffix() {
        let date = dateFromComponents(2026, 11, 9, 22, 45, 3)
        let name = RenameFormatter.fileName(
            date: date, millisecond: "123", custom: "婚纱", extension: "JPG"
        )
        XCTAssertEqual(name, "20261109_224503_123_婚纱.JPG")
    }

    func testFileNameWithoutCustomSuffix() {
        let date = dateFromComponents(2026, 11, 9, 22, 45, 3)
        let name = RenameFormatter.fileName(
            date: date, millisecond: "007", custom: "  ", extension: "mov"
        )
        XCTAssertEqual(name, "20261109_224503_007.mov")
    }

    func testCustomSuffixStripsIllegalCharacters() {
        XCTAssertEqual(RenameFormatter.sanitizeCustom("  2026/11:09  "), "2026-11-09")
    }

    // MARK: - 冲突处理

    func testUniqueNamesAddIncrementingSuffix() {
        var used: Set<String> = ["20261109_224503_123.jpg"]
        let first = RenameFormatter.uniqueName(
            desired: "20261109_224503_123.jpg", original: "IMG_0001.jpg", used: &used
        )
        let second = RenameFormatter.uniqueName(
            desired: "20261109_224503_123.jpg", original: "IMG_0002.jpg", used: &used
        )
        XCTAssertEqual(first, "20261109_224503_123-1.jpg")
        XCTAssertEqual(second, "20261109_224503_123-2.jpg")
    }

    func testUniqueNameKeepsOwnOriginalName() {
        var used: Set<String> = ["20261109_224503_123.jpg"]
        let name = RenameFormatter.uniqueName(
            desired: "20261109_224503_123.jpg", original: "20261109_224503_123.jpg", used: &used
        )
        XCTAssertEqual(name, "20261109_224503_123.jpg")
    }

    // MARK: - 拖入项展开（含子目录）

    func testExpandRecursesIntoSubdirectoriesAndFiltersExtensions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("x", at: root.appendingPathComponent("a.jpg"))
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write("x", at: sub.appendingPathComponent("b.JPG"))
        let deep = sub.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try write("x", at: deep.appendingPathComponent("c.mov"))
        try write("x", at: deep.appendingPathComponent("note.txt"))

        let expanded = RenamePlanner.expand([root]).map { $0.lastPathComponent }
        XCTAssertEqual(Set(expanded), Set(["a.jpg", "b.JPG", "c.mov"]))
    }

    func testExpandDeduplicatesAndAcceptsMixedInputs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.png")
        try write("x", at: image)
        let expanded = RenamePlanner.expand([root, image, image])
        XCTAssertEqual(expanded.count, 1)
        XCTAssertEqual(expanded.first?.lastPathComponent, "a.png")
    }

    // MARK: - 原地执行

    func testApplyRenamesInPlace() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("IMG_0001.jpg")
        try write("x", at: original)
        let item = RenameItem(
            url: original,
            capture: nil,
            captureDateText: "20261109_224503 · 文件时间",
            millisecond: "000",
            millisecondSource: .system,
            proposedName: "20261109_224503_000.jpg"
        )
        let (outcome, updated) = await RenamePlanner.apply([item])
        XCTAssertEqual(outcome.renamed, 1)
        XCTAssertEqual(updated.first?.state, .renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("20261109_224503_000.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testApplySkipsWhenNameUnchanged() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("20261109_224503_000.jpg")
        try write("x", at: original)
        let item = RenameItem(
            url: original,
            capture: nil,
            captureDateText: "20261109_224503 · 文件时间",
            millisecond: "000",
            millisecondSource: .system,
            proposedName: original.lastPathComponent
        )
        let (outcome, updated) = await RenamePlanner.apply([item])
        XCTAssertEqual(outcome.unchanged, 1)
        XCTAssertEqual(updated.first?.state, .unchanged)
    }

    // MARK: - 报告存放位置

    /// 造一个已重命名成功的条目（报告写入需要 state == .renamed 且新文件存在）。
    private func renamedItem(in dir: URL) throws -> RenameItem {
        let newURL = dir.appendingPathComponent("20261109_224503_000.jpg")
        try write("x", at: newURL)
        var item = RenameItem(
            url: dir.appendingPathComponent("IMG_0001.jpg"),
            capture: nil,
            captureDateText: "20261109_224503 · 文件时间",
            millisecond: "000",
            millisecondSource: .system,
            proposedName: "20261109_224503_000.jpg"
        )
        item.state = .renamed
        return item
    }

    func testRenameReportPlacementNoneWritesNothing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try renamedItem(in: root)
        let urls = try await RenameMHL.write(
            items: [item], startedAt: Date(), finishedAt: Date(),
            placement: ReportPlacement(writeAlongside: false, customDirectory: "")
        )
        XCTAssertTrue(urls.isEmpty)
        let reports = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mhl" || $0.pathExtension == "pdf" } ?? []
        XCTAssertTrue(reports.isEmpty)
    }

    func testRenameReportPlacementCustomOnlyWritesToCustomDir() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("reports")
        let item = try renamedItem(in: root)
        let urls = try await RenameMHL.write(
            items: [item], startedAt: Date(), finishedAt: Date(),
            placement: ReportPlacement(writeAlongside: false, customDirectory: custom.path)
        )
        XCTAssertEqual(urls.count, 2, "一组 MHL + PDF")
        for url in urls {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                           custom.standardizedFileURL.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testRenameReportPlacementBothWritesToBothDirs() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("reports")
        let item = try renamedItem(in: root)
        let urls = try await RenameMHL.write(
            items: [item], startedAt: Date(), finishedAt: Date(),
            placement: ReportPlacement(writeAlongside: true, customDirectory: custom.path)
        )
        XCTAssertEqual(urls.count, 4)
        let inRoot = urls.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
        }
        let inCustom = urls.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path == custom.standardizedFileURL.path
        }
        XCTAssertEqual(inRoot.count, 2)
        XCTAssertEqual(inCustom.count, 2)
    }

    // MARK: - EXIF 字典解析（注入 ImageIO 写入端无法生成的子秒字段）

    func testEXIFSubSecondTwoDigitsProducesPaddedName() async throws {
        let props = exifProperties(date: "2026:11:09 22:45:03", subsecond: "12")
        let capture = EXIFReader.capture(fromProperties: props)
        XCTAssertEqual(capture?.source, .exif)
        XCTAssertEqual(capture?.subsecondRaw, "12")
        let (ms, source) = RenameFormatter.millisecond(raw: capture?.subsecondRaw)
        XCTAssertEqual(ms, "120")
        XCTAssertEqual(source, .exifPadded)
        let name = RenameFormatter.fileName(
            date: capture!.date, millisecond: ms, custom: "测试", extension: "jpg"
        )
        XCTAssertEqual(name, "20261109_224503_120_测试.jpg")
    }

    func testEXIFSubSecondAsNumberIsAccepted() {
        let props = exifProperties(date: "2026:11:09 22:45:03", subsecond: NSNumber(value: 7))
        XCTAssertEqual(EXIFReader.capture(fromProperties: props)?.subsecondRaw, "7")
    }

    func testEXIFFractionalDateTimeIsUsedAsSubSecond() {
        let props = exifProperties(date: "2026:11:09 22:45:03.12", subsecond: nil)
        let capture = EXIFReader.capture(fromProperties: props)
        XCTAssertEqual(capture?.subsecondRaw, "12")
        XCTAssertEqual(RenameFormatter.timestamp(capture!.date).split(separator: "_"), ["20261109", "224503"])
    }

    func testEXIFWithoutSubSecondFallsBackToSystemMillisecond() {
        let props = exifProperties(date: "2026:11:09 22:45:03", subsecond: nil)
        let capture = EXIFReader.capture(fromProperties: props)
        XCTAssertNil(capture?.subsecondRaw)
        let (_, source) = RenameFormatter.millisecond(raw: capture?.subsecondRaw)
        XCTAssertEqual(source, .system)
    }

    // MARK: - 真实 JPEG 文件

    func testRealJPEGEXIFDateIsUsed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("IMG_0001.jpg")
        try writeJPEGWithEXIF(to: url, dateTimeOriginal: "2026:11:09 22:45:03")

        let capture = await EXIFReader.read(url: url)
        XCTAssertEqual(capture?.source, .exif)
        XCTAssertEqual(RenameFormatter.timestamp(capture!.date).split(separator: "_"), ["20261109", "224503"])
        let items = await RenamePlanner.preview(for: [url], custom: "测试")
        XCTAssertEqual(items.first?.millisecondSource, .system)
        XCTAssertTrue(items.first?.proposedName.hasPrefix("20261109_224503_") ?? false)
        XCTAssertTrue(items.first?.proposedName.hasSuffix("_测试.jpg") ?? false)
    }

    func testFileWithoutEXIFFallsBackToSystemMillisecond() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("plain.jpg")
        try write("not a real image", at: url)

        let capture = await EXIFReader.read(url: url)
        XCTAssertEqual(capture?.source, .file)
        let items = await RenamePlanner.preview(for: [url], custom: "")
        let name = items.first?.proposedName ?? ""
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertEqual(name.split(separator: "_").count, 3) // 日期_时分秒_毫秒.jpg
        XCTAssertEqual(items.first?.millisecondSource, .system)
    }

    // MARK: - 端到端：递归展开 → 预览 → 各自原目录原地改名

    func testEndToEndRecursionPreviewAndApplyInPlace() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("sub/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("IMG_0001.jpg")
        try writeJPEGWithEXIF(to: photo, dateTimeOriginal: "2026:11:09 22:45:03")
        let clip = deep.appendingPathComponent("clip.mov")
        try write("fake video", at: clip)
        try write("ignore", at: deep.appendingPathComponent("note.txt"))

        let files = RenamePlanner.expand([root])
        XCTAssertEqual(files.count, 2)

        let items = await RenamePlanner.preview(for: files, custom: "拍摄")
        XCTAssertEqual(items.count, 2)
        let (outcome, updated) = await RenamePlanner.apply(items)
        XCTAssertEqual(outcome.renamed, 2)
        XCTAssertEqual(updated.filter { $0.state == .renamed }.count, 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(rootNames.contains { $0.hasPrefix("20261109_224503_") && $0.hasSuffix("_拍摄.jpg") })
        let deepNames = try FileManager.default.contentsOfDirectory(atPath: deep.path)
        XCTAssertTrue(deepNames.contains { $0.hasSuffix("_拍摄.mov") }, "子目录文件应在原目录内改名")
        XCTAssertTrue(deepNames.contains("note.txt"), "不支持的扩展名不应被改动")
    }

    // MARK: - 暂停 / 停止

    func testApplyStopKeepsCompletedAndPending() async throws {
        let fm = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        try write("x", at: root.appendingPathComponent("IMG_0001.jpg"))
        try write("y", at: root.appendingPathComponent("IMG_0002.jpg"))
        let files = RenamePlanner.expand([root])
        XCTAssertEqual(files.count, 2)
        let items = await RenamePlanner.preview(for: files, custom: "")
        let control = RunControl()
        let (outcome, updated) = await RenamePlanner.apply(
            items, control: control, onProgress: { done, _, _ in
                if done == 1 { control.stop() }
            }
        )
        XCTAssertEqual(outcome.renamed, 1)
        XCTAssertEqual(updated.filter { $0.state == .renamed }.count, 1)
        XCTAssertEqual(updated.filter { $0.state == .pending }.count, 1)
        let names = try fm.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("IMG_") }.count, 1, "未处理文件应保留原名")
    }

    func testPreviewStopReturnsNoPartialPreview() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("x", at: root.appendingPathComponent("a.jpg"))
        try write("y", at: root.appendingPathComponent("b.jpg"))
        let files = RenamePlanner.expand([root])
        let control = RunControl()
        control.stop()
        let scanned = await RenamePlanner.previewControlled(
            for: files, custom: "", control: control
        )
        XCTAssertTrue(scanned.stopped)
        XCTAssertTrue(scanned.items.isEmpty, "停止扫描不应基于不完整的 EXIF 数据生成预览")
    }

    // MARK: - Helpers

    private func exifProperties(date: String, subsecond: Any?) -> [String: Any] {
        var exif: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: date]
        if let subsecond { exif["SubSecTimeOriginal"] = subsecond }
        return [kCGImagePropertyExifDictionary as String: exif]
    }

    private func writeJPEGWithEXIF(to url: URL, dateTimeOriginal: String) throws {
        let context = CGContext(
            data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else {
            throw XCTSkip("无法创建测试图片")
        }
        let exif: [String: Any] = [
            kCGImagePropertyExifDateTimeOriginal as String: dateTimeOriginal,
        ]
        let properties: [String: Any] = [kCGImagePropertyExifDictionary as String: exif]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func dateFromComponents(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = y
        components.month = m
        components.day = d
        components.hour = h
        components.minute = min
        components.second = s
        return components.date!
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitRenameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
