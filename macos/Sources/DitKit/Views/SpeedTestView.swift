import SwiftUI
import AppKit
import DitKitCore

/// 磁盘顺序读写测速页：选目录 → 选大小 → 开始 → 进度 → 结果。
/// 只做顺序写与顺序读，不做随机 IO；测试文件由 DitKitCore 自动创建并删除。
struct SpeedTestView: View {
    var embedded: Bool = false
    @State private var controller = SpeedTestController()

    private let readColor = Color(red: 0.36, green: 0.72, blue: 1.0)
    private let writeColor = Color(red: 1.0, green: 0.38, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            infoBar
            configCard
            if let progress = controller.progress {
                progressCard(progress)
            }
            if let result = controller.result {
                resultCard(result)
            }
            statusBanner
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity, alignment: .topLeading)
        // 仅供联调：--speedtest-run 自动开始，无需 GUI 点击。
        .onAppear {
            if SpeedTestController.shouldAutoStart,
               controller.directoryURL != nil,
               !controller.isRunning,
               controller.result == nil {
                controller.start()
            }
        }
    }

    // MARK: 顶部说明条

    private var infoBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "speedometer").font(.title3)
            Text("顺序读写测速").font(.headline)
            Text("· 二进制 GiB 口径 · 临时文件自动删除")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.10), in: Capsule())
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return "就绪"
        case .running: return "正在测速"
        case .cancelling: return "正在取消"
        case .finished: return "测速完成"
        case .cancelled: return "已取消"
        case .failed: return "出错"
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .idle: return .secondary
        case .running: return .orange
        case .cancelling: return .orange
        case .finished: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    // MARK: 配置卡片

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text("测试大小").font(.subheadline.weight(.medium))
                Picker("测试大小", selection: $controller.size) {
                    ForEach(SpeedTestSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .disabled(controller.isRunning)
                Text(controller.size.note).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text("目标目录").font(.subheadline.weight(.medium))
                Text(controller.directoryURL?.path ?? "尚未选择，请先选择要测的磁盘目录")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(controller.directoryURL == nil ? .orange : .secondary)
                Spacer(minLength: 0)
                Button("选择目录…") { controller.chooseDirectory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.isRunning)
            }

            HStack(spacing: 12) {
                Text("只测顺序写入与顺序读取；写入与读取均绕过页缓存，写入后强制落盘；测前检查可用空间并预留 1 GiB 余量；结束后只删除本次创建的临时文件。SSD 自身缓存仍可能影响读数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if controller.phase == .cancelling {
                    Button("取消中…") { }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(true)
                } else if controller.isRunning {
                    Button("取消测速") { controller.cancel() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                } else {
                    Button("开始测速") { controller.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)
                        .disabled(controller.directoryURL == nil)
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    // MARK: 进度卡片

    private func progressCard(_ progress: SpeedTestProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.stageText).font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.0f%%", progress.fraction * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
            Text(progress.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .cardBackground()
    }

    // MARK: 结果卡片

    private func resultCard(_ result: SpeedTestResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                ResultBlock(title: "顺序写入速度", value: SpeedFormat.speed(result.writeBytesPerSecond),
                            color: writeColor)
                Divider().frame(height: 62)
                ResultBlock(title: "顺序读取速度", value: SpeedFormat.speed(result.readBytesPerSecond),
                            color: readColor)
                Divider().frame(height: 62)
                VStack(alignment: .leading, spacing: 6) {
                    Text("耗时").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "写 %.2f 秒", result.writeSeconds)).font(.caption)
                    Text(String(format: "读 %.2f 秒", result.readSeconds)).font(.caption)
                    Text(String(format: "合计 %.2f 秒", result.writeSeconds + result.readSeconds))
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }

            Divider()

            HStack(spacing: 18) {
                Label(SpeedFormat.size(result.bytes), systemImage: "externaldrive")
                Label(result.directory, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("完成于 \(result.finishedAt.formatted(date: .omitted, time: .standard))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .cardBackground()
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch controller.phase {
        case .finished:
            Banner(text: "测速完成，临时文件已自动删除。写入计时包含强制落盘，读写均绕过页缓存；SSD 自身缓存仍可能影响读数。", color: .green)
        case .cancelled:
            Banner(text: "测速已取消，临时文件已清理。", color: .orange)
        case .failed(let message):
            Banner(text: message, color: .red)
        default:
            EmptyView()
        }
    }
}

private struct ResultBlock: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .light, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

private struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(color)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
