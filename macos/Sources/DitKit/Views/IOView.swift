import SwiftUI
import DitKitCore

/// 实时磁盘读写 IO 面板：四个大数字 + 双曲线折线图。
/// 采样间隔 0.5 秒（500 毫秒），时间窗口固定 10 分钟（1200 点），不提供缩放，横轴刻度始终一致。
struct IOView: View {
    var embedded: Bool = false
    @State private var monitor = IOMonitor(interval: 0.5, historySeconds: 600)
    @State private var exportMessage = ""
    @State private var didStart = false

    private let readColor = Color(red: 0.36, green: 0.72, blue: 1.0)
    private let writeColor = Color(red: 1.0, green: 0.38, blue: 0.42)
    private static let allKey = "__all_physical_disks__"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar
            metricsCard
            chartCard
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity, alignment: .topLeading)
        // 切换标签不停止采样，历史曲线得以保留；用户手动停止后也不会被自动重启。
        .onAppear {
            if !didStart {
                didStart = true
                monitor.start()
            }
        }
    }

    private var peakSpeed: Double {
        monitor.samples.reduce(1_000_000) {
            max($0, max($1.readBytesPerSecond, $1.writeBytesPerSecond))
        }
    }

    private var peakIOPS: Double {
        monitor.samples.reduce(100) { max($0, max($1.readOpsPerSecond, $1.writeOpsPerSecond)) }
    }

    // MARK: 顶部信息条

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon).font(.title3)
                Text(monitor.selectedDevice?.displayName ?? "全部物理磁盘")
                    .font(.headline)
                Text("·").foregroundStyle(.secondary)
                Text(monitor.devices.isEmpty ? "IOKit" : "\(monitor.devices.count) 块物理磁盘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(monitor.isRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(monitor.isRunning ? "正常 · 正在监控" : "已停止监控")
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.10), in: Capsule())
                Text("IOKit 直采")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("监控磁盘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("监控磁盘", selection: Binding(
                    get: { monitor.selectedKey ?? Self.allKey },
                    set: { monitor.select($0 == Self.allKey ? nil : $0) }
                )) {
                    Text("全部物理磁盘（合计）").tag(Self.allKey)
                    ForEach(monitor.devices) { device in
                        Text(device.displayName).tag(device.key)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 440)
                Spacer(minLength: 8)
                Text("切换后曲线重新起步")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = monitor.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var headerIcon: String {
        guard let device = monitor.selectedDevice else { return "internaldrive" }
        return device.isInternal ? "internaldrive" : "externaldrive"
    }

    /// 「全部」显示启动卷容量；选中具体磁盘时改为该盘的型号/介质/整盘容量，避免误导。
    private var volumeSummary: String {
        if let device = monitor.selectedDevice {
            var parts = [device.displayName]
            if !device.capacityText.isEmpty { parts.append("总容量 \(device.capacityText)") }
            return parts.joined(separator: " · ")
        }
        return monitor.volume?.summary ?? "正在读取卷容量…"
    }

    // MARK: 四个大数字

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                MetricBlock(title: "读取速度", number: readNumber, unit: readUnit,
                            level: monitor.current.readSpeed / peakSpeed, color: readColor)
                MetricDivider()
                MetricBlock(title: "写入速度", number: writeNumber, unit: writeUnit,
                            level: monitor.current.writeSpeed / peakSpeed, color: writeColor)
                MetricDivider()
                MetricBlock(title: "读操作频率", number: readOps, unit: "次/秒",
                            level: monitor.current.readIOPS / peakIOPS, color: readColor)
                MetricDivider()
                MetricBlock(title: "写操作频率", number: writeOps, unit: "次/秒",
                            level: monitor.current.writeIOPS / peakIOPS, color: writeColor)
            }
            HStack {
                Text(volumeSummary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button(monitor.isRunning ? "停止监控" : "开始监控") {
                    monitor.toggle()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(monitor.isRunning ? .orange : .green)
            }
        }
        .padding(16)
        .background(Color(red: 0.20, green: 0.24, blue: 0.21))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var readNumber: String { IOFormat.speedParts(monitor.current.readSpeed).0 }
    private var readUnit: String { IOFormat.speedParts(monitor.current.readSpeed).1 }
    private var writeNumber: String { IOFormat.speedParts(monitor.current.writeSpeed).0 }
    private var writeUnit: String { IOFormat.speedParts(monitor.current.writeSpeed).1 }
    private var readOps: String { String(format: "%.0f", monitor.current.readIOPS.rounded()) }
    private var writeOps: String { String(format: "%.0f", monitor.current.writeIOPS.rounded()) }

    // MARK: 图表卡片

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("实时 IO 图表").font(.headline)
                Spacer()
                Text("采样 \(Int((monitor.interval * 1000).rounded())) 毫秒 · 窗口 \(monitor.historySeconds / 60) 分钟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    monitor.clear()
                } label: {
                    Label("清空", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            IOChart(samples: monitor.samples, windowSeconds: monitor.historySeconds)
                .frame(minHeight: embedded ? 190 : 268, maxHeight: .infinity)

            HStack(spacing: 10) {
                if !exportMessage.isEmpty {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    exportMessage = IOChartExporter.save(
                        samples: monitor.samples,
                        windowSeconds: monitor.historySeconds,
                        interval: monitor.interval
                    )
                } label: {
                    Label("导出图表", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .cardBackground()
    }
}

private struct MetricBlock: View {
    let title: String
    let number: String
    let unit: String
    let level: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(number)
                    .font(.system(size: 34, weight: .light, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            LevelBar(value: min(1, max(0, level)), color: color)
                .frame(height: 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

private struct MetricDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.15))
            .frame(height: 76)
    }
}

private struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<22, id: \.self) { index in
                Rectangle()
                    .fill(Double(index) / 22 < value ? color : Color.white.opacity(0.13))
                    .frame(width: 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }
}
