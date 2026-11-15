import XCTest
@testable import DitKitCore

final class IOModelsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testRateCalculation() throws {
        let prev = IOCounters(readBytes: 1_000_000, writeBytes: 500_000,
                              readOps: 100, writeOps: 50, timestamp: t0)
        let curr = IOCounters(readBytes: 3_000_000, writeBytes: 1_500_000,
                              readOps: 300, writeOps: 150, timestamp: t0.addingTimeInterval(2))
        let sample = try XCTUnwrap(IORate.sample(from: prev, to: curr))
        XCTAssertEqual(sample.readBytesPerSecond, 1_000_000, accuracy: 0.001)
        XCTAssertEqual(sample.writeBytesPerSecond, 500_000, accuracy: 0.001)
        XCTAssertEqual(sample.readOpsPerSecond, 100, accuracy: 0.001)
        XCTAssertEqual(sample.writeOpsPerSecond, 50, accuracy: 0.001)
        XCTAssertEqual(IORate.metrics(from: sample).peakSpeed, 1_000_000)
    }

    /// 计数器被系统重置时不能出现负速率或天文数字。
    func testCounterResetProducesZeroNotNegative() throws {
        let prev = IOCounters(readBytes: 900_000, writeBytes: 900_000,
                              readOps: 900, writeOps: 900, timestamp: t0)
        let curr = IOCounters(readBytes: 10, writeBytes: 10,
                              readOps: 1, writeOps: 1, timestamp: t0.addingTimeInterval(1))
        let sample = try XCTUnwrap(IORate.sample(from: prev, to: curr))
        XCTAssertEqual(sample.readBytesPerSecond, 0)
        XCTAssertEqual(sample.writeBytesPerSecond, 0)
        XCTAssertEqual(sample.readOpsPerSecond, 0)
    }

    func testInvalidElapsedTimeIsIgnored() {
        let prev = IOCounters(readBytes: 0, timestamp: t0)
        XCTAssertNil(IORate.sample(from: prev, to: IOCounters(readBytes: 1, timestamp: t0)))
        XCTAssertNil(IORate.sample(from: prev,
                                   to: IOCounters(readBytes: 1, timestamp: t0.addingTimeInterval(120))))
    }

    func testRingBufferKeepsExactlyTenMinutes() {
        var series = IOSeries(capacity: 600)
        for i in 0..<605 {
            series.append(IOSample(timestamp: t0.addingTimeInterval(Double(i)),
                                   readBytesPerSecond: Double(i)))
        }
        XCTAssertEqual(series.samples.count, 600)
        XCTAssertEqual(series.samples.first?.readBytesPerSecond, 5)
        XCTAssertEqual(series.samples.last?.readBytesPerSecond, 604)
        XCTAssertEqual(series.peakBytesPerSecond, 604)
        series.clear()
        XCTAssertTrue(series.samples.isEmpty)
    }

    @MainActor
    func testDefaultMonitorCapacityIsSixHundredPoints() {
        let monitor = IOMonitor(interval: 1, historySeconds: 600)
        XCTAssertEqual(monitor.capacity, 600)
        XCTAssertEqual(monitor.historySeconds, 600)
    }

    /// 10 分钟窗口的点数必须随采样间隔自动缩放；采样器下限不能把小间隔抬高。
    @MainActor
    func testCapacityScalesWithSamplingInterval() {
        let cases: [(TimeInterval, Int)] = [(1, 600), (0.5, 1200), (0.1, 6000)]
        for (interval, expected) in cases {
            let monitor = IOMonitor(interval: interval, historySeconds: 600)
            XCTAssertEqual(monitor.interval, interval, accuracy: 1e-9)
            XCTAssertEqual(monitor.historySeconds, 600)
            // 600 / 0.1 在二进制浮点里是 5999.999…，向下取整会少一个点。
            XCTAssertEqual(monitor.capacity, expected)
        }
        XCTAssertEqual(IOMonitor(interval: 0.01, historySeconds: 600).interval,
                       0.05, accuracy: 1e-9)
    }

    /// 环形缓冲在高频采样下仍严格只保留窗口长度。
    func testRingBufferAtHighRate() {
        var series = IOSeries(capacity: 1200)
        for i in 0..<1210 {
            series.append(IOSample(timestamp: t0.addingTimeInterval(Double(i) * 0.5),
                                   readBytesPerSecond: Double(i)))
        }
        XCTAssertEqual(series.samples.count, 1200)
        XCTAssertEqual(series.samples.first?.readBytesPerSecond, 10)
    }

    func testChineseFormatting() {
        XCTAssertEqual(IOFormat.speed(20_900_000), "20.9 MB/秒")
        XCTAssertEqual(IOFormat.speed(0), "0 B/秒")
        XCTAssertEqual(IOFormat.ops(892.4), "892 次/秒")
        let parts = IOFormat.speedParts(100_700_000)
        XCTAssertEqual(parts.0, "100.7")
        XCTAssertEqual(parts.1, "MB/秒")
        XCTAssertTrue(IOFormat.capacity(1_995_165_736_960).contains("太字节"))
        XCTAssertFalse(IOFormat.capacity(1_995_165_736_960).contains("TiB"))
        XCTAssertTrue(IOFormat.axis(15_000_000_000).contains("吉字节/秒"))
    }

    /// 固定 10 分钟时间轴：每 2 分钟一条竖线，不能出现 6.7 / 3.3 分钟这种三分刻度。
    func testTimeGridIsEveryTwoMinutes() {
        let lines = IOGrid.verticalLines(windowSeconds: 600)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines.map { $0.minutesAgo }, [10, 8, 6, 4, 2, 0])
        XCTAssertEqual(lines.map { IOGrid.timeLabel(minutesAgo: $0.minutesAgo) },
                       ["10 分钟前", "8 分钟前", "6 分钟前", "4 分钟前", "2 分钟前", "现在"])
        let ratios = lines.map { $0.ratio }
        for (index, expected) in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0].enumerated() {
            XCTAssertEqual(ratios[index], expected, accuracy: 1e-9)
        }
        XCTAssertEqual(IOGrid.stepSeconds, 120)
    }

    /// 同一组刻度必须用同一个单位且互不重复（早期版本取整后出现两个「2 兆字节/秒」）。
    func testAxisTicksAreDistinctAndShareOneUnit() {
        let ceiling = 3_000_000.0
        let ticks = (0...5).map { IOFormat.axis(ceiling * Double($0) / 5, ceiling: ceiling) }
        XCTAssertEqual(Set(ticks).count, 6)
        XCTAssertTrue(ticks.dropFirst().allSatisfy { $0.contains("MB/秒") })
        let integerTicks = (0...5).map {
            IOFormat.axis(20_000_000 * Double($0) / 5, ceiling: 20_000_000)
        }
        XCTAssertEqual(integerTicks.last, "20 MB/秒")
        XCTAssertEqual(integerTicks[1], "4 MB/秒")
        XCTAssertEqual(IOFormat.capacity(2_000_000_000_000), "2 太字节")
    }
}
