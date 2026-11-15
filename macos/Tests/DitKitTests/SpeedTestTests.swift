import XCTest
@testable import DitKitCore

final class SpeedTestTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKitSpeedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: 纯计算

    func testSizesUseBinaryGibiBytes() {
        XCTAssertEqual(SpeedTestSize.oneGiB.bytes, 1_073_741_824)
        XCTAssertEqual(SpeedTestSize.tenGiB.bytes, 10_737_418_240)
        XCTAssertEqual(SpeedTestSize.hundredGiB.bytes, 107_374_182_400)
        XCTAssertEqual(SpeedTestSize.allCases.map(\.label), ["1 GiB", "10 GiB", "100 GiB"])
        XCTAssertEqual(SpeedTestSize.default, .oneGiB)
    }

    func testBinaryFormatting() {
        XCTAssertEqual(SpeedFormat.size(1_073_741_824), "1 GiB")
        XCTAssertEqual(SpeedFormat.size(512 * 1024 * 1024), "512 MiB")
        XCTAssertEqual(SpeedFormat.speed(1_048_576), "1 MiB/秒")
        XCTAssertEqual(SpeedFormat.speed(0), "0 MiB/秒")
        XCTAssertTrue(SpeedFormat.speed(2 * 1024 * 1024 * 1024).contains("GiB/秒"))
    }

    func testSpaceCheckRequiresOneGiBMargin() {
        let oneGiB = SpeedTestSize.oneGiB.bytes
        XCTAssertTrue(SpeedTestMath.canRun(available: oneGiB * 2, size: oneGiB))
        XCTAssertFalse(SpeedTestMath.canRun(available: oneGiB + 1, size: oneGiB))
        XCTAssertEqual(SpeedTestMath.requiredFreeBytes(for: oneGiB), oneGiB * 2)
    }

    func testProgressAndMath() {
        let total = SpeedTestSize.tenGiB.bytes
        XCTAssertEqual(SpeedTestProgress(stage: .writing, bytesDone: total / 2, totalBytes: total).fraction,
                       0.25, accuracy: 0.0001)
        XCTAssertEqual(SpeedTestProgress(stage: .reading, bytesDone: total / 2, totalBytes: total).fraction,
                       0.75, accuracy: 0.0001)
        XCTAssertEqual(SpeedTestMath.bytesPerSecond(1_000, seconds: 0.5), 2_000)
        XCTAssertEqual(SpeedTestMath.bytesPerSecond(1_000, seconds: 0), 0)
        XCTAssertEqual(SpeedTestMath.blockCount(total: 10, blockSize: 4), 3)
    }

    // MARK: 真实小样本 IO（写 → 读 → 清理）

    func testRunnerWritesReadsAndCleansUp() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes: Int64 = 8 * 1024 * 1024
        let config = SpeedTestConfig(bytes: bytes, directoryURL: dir, blockSize: 1024 * 1024)
        let box = ProgressBox()

        let result = try await SpeedTestRunner.run(
            config: config,
            progress: { box.add($0) },
            isCancelled: { false }
        )

        XCTAssertEqual(result.bytes, bytes)
        XCTAssertGreaterThan(result.writeSeconds, 0)
        XCTAssertGreaterThan(result.readSeconds, 0)
        XCTAssertGreaterThan(result.writeBytesPerSecond, 0)
        XCTAssertGreaterThan(result.readBytesPerSecond, 0)
        XCTAssertTrue(box.stages.contains(.writing))
        XCTAssertTrue(box.stages.contains(.reading))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty,
                      "临时文件必须被自动删除")
    }

    func testCancellationThrowsAndCleansUp() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = SpeedTestConfig(bytes: 64 * 1024 * 1024, directoryURL: dir, blockSize: 1024 * 1024)

        do {
            _ = try await SpeedTestRunner.run(config: config, progress: { _ in }, isCancelled: { true })
            XCTFail("应立即取消")
        } catch let error as SpeedTestError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testInsufficientSpaceRejectsBeforeCreatingFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = SpeedTestConfig(bytes: 1_000_000_000_000_000, directoryURL: dir)

        do {
            _ = try await SpeedTestRunner.run(config: config, progress: { _ in }, isCancelled: { false })
            XCTFail("空间不足应被拒绝")
        } catch let error as SpeedTestError {
            guard case .insufficientSpace = error else { return XCTFail("错误类型不符：\(error)") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testMissingDirectoryIsRejected() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("DitKit-不存在-\(UUID().uuidString)", isDirectory: true)
        let config = SpeedTestConfig(bytes: 1024 * 1024, directoryURL: missing)

        do {
            _ = try await SpeedTestRunner.run(config: config, progress: { _ in }, isCancelled: { false })
            XCTFail("不存在的目录应被拒绝")
        } catch let error as SpeedTestError {
            guard case .directoryMissing = error else { return XCTFail("错误类型不符：\(error)") }
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SpeedTestStage] = []

    func add(_ progress: SpeedTestProgress) {
        lock.lock()
        defer { lock.unlock() }
        values.append(progress.stage)
    }

    var stages: [SpeedTestStage] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
