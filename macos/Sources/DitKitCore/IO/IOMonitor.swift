import Foundation
import Observation

/// 实时 IO 采样状态机。默认 1 秒采样；界面使用 0.5 秒采样，保留 10 分钟。
/// 环形缓冲容量按「窗口秒数 ÷ 采样间隔」自动计算（0.5 秒 → 1200 点，100 毫秒 → 6000 点）。
/// 采集完全在 Swift 侧通过 IOKit 完成，不依赖 Go 后端，也不产生子进程。
///
/// 只统计**物理盘**（APFS 合成盘已在 IOKitCounters 层排除，避免重复计数）。
/// `selectedKey == nil` 显示所有物理盘合计；选中某块盘时数字与曲线只反映该盘。
@MainActor
@Observable
public final class IOMonitor {
    public private(set) var isRunning = false
    public private(set) var samples: [IOSample] = []
    public private(set) var current = IOMetrics.zero
    public private(set) var volume: IOVolumeInfo?
    public private(set) var devices: [IODevice] = []
    public private(set) var deviceNames: [String] = []
    /// nil = 全部物理磁盘；否则为某块物理盘的 BSD 名（如 disk4）。
    public private(set) var selectedKey: String?
    public private(set) var errorMessage: String?

    public var selectedDevice: IODevice? { devices.first { $0.key == selectedKey } }

    public let interval: TimeInterval
    public let historySeconds: Int
    public let capacity: Int

    @ObservationIgnored private var series: IOSeries
    @ObservationIgnored private var baselines: [String: IOCounters] = [:]
    @ObservationIgnored private var baselineAt: Date = .distantPast
    @ObservationIgnored private var timer: Timer?

    public init(interval: TimeInterval = 1, historySeconds: Int = 600) {
        self.interval = max(0.05, interval)
        self.historySeconds = max(10, historySeconds)
        // 用四舍五入而非向下取整：600 / 0.1 在二进制浮点里是 5999.999…，向下取整会少一点。
        let cap = Int((Double(self.historySeconds) / self.interval).rounded())
        self.capacity = max(2, cap)
        self.series = IOSeries(capacity: max(2, cap))
    }

    deinit {
        // 窗口/视图释放时不要留下每秒空转的 Timer（Timer 对 self 是 weak，但闭包本身仍在跑）。
        timer?.invalidate()
    }

    public func start() {
        guard !isRunning else { return }
        devices = IOKitCounters.devices()
        deviceNames = devices.map(\.bsdName)
        volume = IOKitCounters.volumeInfo()
        // 外置盘被拔出后不要留一个不存在的选择。
        if let selectedKey, !devices.contains(where: { $0.key == selectedKey }) {
            self.selectedKey = nil
        }
        resetBaseline()
        refreshErrorMessage()
        isRunning = true

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = interval * 0.1
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    public func toggle() {
        isRunning ? stop() : start()
    }

    /// 切换监控的磁盘。运行中会重建基线并清空曲线，避免把两块盘的累计值混在一个窗口里。
    public func select(_ key: String?) {
        guard key != selectedKey else { return }
        selectedKey = key
        if isRunning {
            resetBaseline()
            refreshErrorMessage()
        }
    }

    /// 清空历史但保持监控运行，以当前累计值重建基线。
    public func clear() {
        resetBaseline()
    }

    private func resetBaseline() {
        let snapshots = IOKitCounters.snapshot()
        var map: [String: IOCounters] = [:]
        for snapshot in snapshots { map[snapshot.key] = snapshot.counters }
        baselines = map
        baselineAt = Date()
        // 曲线从 0 起步，避免窗口刚打开（或刚切换磁盘）时是一片空白。
        series.clear()
        series.append(IOSample())
        samples = series.samples
        current = .zero
    }

    private func refreshErrorMessage() {
        guard !devices.isEmpty else {
            errorMessage = "IOKit 未找到物理磁盘"
            return
        }
        let hasCounters = IOKitCounters.snapshot()
            .filter { selectedKey == nil || $0.key == selectedKey }
            .contains { $0.counters.readBytes > 0 || $0.counters.writeBytes > 0 }
        errorMessage = hasCounters ? nil : "所选磁盘未提供 IOKit 统计计数器"
    }

    /// 在后台线程遍历 IORegistry，避免每秒一次的同步采样阻塞主线程 UI。
    private nonisolated func fetchCounters() async -> ([IODeviceSnapshot], Date) {
        let now = Date()
        let snapshots = await Task.detached(priority: .utility) {
            IOKitCounters.snapshot()
        }.value
        return (snapshots, now)
    }

    private func tick() async {
        // IOKitRegistry 遍历放到后台；只把最终数值 hop 回主 actor 更新界面。
        let (snapshots, nowAt) = await fetchCounters()
        var nowByKey: [String: IOCounters] = [:]
        for snapshot in snapshots { nowByKey[snapshot.key] = snapshot.counters }

        var previous = IOCounters(timestamp: baselineAt)
        var now = IOCounters(timestamp: nowAt)
        for (key, counters) in nowByKey where selectedKey == nil || key == selectedKey {
            let base = baselines[key] ?? IOCounters(timestamp: baselineAt)
            previous = previous.combined(with: base)
            now = now.combined(with: counters)
        }
        if let sample = IORate.sample(from: previous, to: now) {
            series.append(sample)
            samples = series.samples
            current = IORate.metrics(from: sample)
        }
        baselines = nowByKey
        baselineAt = nowAt
    }
}
