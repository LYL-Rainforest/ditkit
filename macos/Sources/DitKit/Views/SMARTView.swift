import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DitKitCore

struct SMARTView: View {
    let state: AppState

    // 磁盘列表常驻：不用 NavigationSplitView，也就没有系统自动插入的
    // 「显示/隐藏侧边栏」切换按钮，窗口状态恢复同样无法把它折叠掉。
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(connectionColor).frame(width: 8, height: 8)
                Text(state.statusMessage).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            Divider()
            List {
                Section("已发现的磁盘") {
                    ForEach(state.disks) { disk in
                        Button {
                            Task { await state.selectDisk(disk.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(disk.label).font(.system(size: 13, weight: .medium))
                                Text(disk.protocolName).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            state.selectedDiskID == disk.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = state.errorMessage {
                    errorBanner(error)
                }
                if let report = state.report {
                    summaryCard(report)
                    ForEach(report.sections) { section in
                        SectionCard(section: section)
                    }
                    if !report.warnings.isEmpty {
                        bulletCard(title: "需要留意", items: report.warnings, color: .orange)
                    }
                    if !report.messages.isEmpty {
                        bulletCard(title: "工具提示（已翻译为中文）", items: report.messages, color: .secondary)
                    }
                    bulletCard(title: "命令退出码 \(report.exitCode) 说明", items: report.exitNotes, color: .secondary)
                    Text("本报告由 smartctl 原始 JSON 逐字段翻译生成，未改动任何数值。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "internaldrive").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("等待磁盘数据").font(.headline)
                        Text("正在连接采集后端，或点击右上角「重新连接并刷新」重试")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryCard(_ r: ReportDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("总体结论").font(.caption).foregroundStyle(.secondary)
                Text(r.overall).font(.system(size: 28, weight: .medium))
                StatusPill(status: r.status)
                Spacer()
                Button {
                    SMARTReportExporter.export(r)
                } label: {
                    Label("导出图片", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            }
            Text(r.summary).font(.subheadline)
            HStack(spacing: 18) {
                Label(r.device.label, systemImage: "internaldrive")
                Text("生成时间：\(r.generatedAt)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func bulletCard(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Text("· " + item)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var connectionColor: Color {
        switch state.connection {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }
}

private struct SectionCard: View {
    let section: SectionDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title).font(.headline).padding(.bottom, 4)
            ForEach(section.rows) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 190, alignment: .leading)
                    Text(item.value)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.status == "warn" || item.status == "critical" {
                        StatusPill(status: item.status)
                    }
                }
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 202)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().opacity(0.35)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

private struct StatusPill: View {
    let status: String

    private var label: String {
        switch status {
        case "critical": return "严重"
        case "warn": return "警告"
        case "ok": return "正常"
        default: return "参考"
        }
    }

    private var color: Color {
        switch status {
        case "critical": return .red
        case "warn": return .orange
        case "ok": return .green
        default: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension View {
    func cardBackground() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
    }
}

// MARK: - 报告导出为图片（PNG）

/// 把整份 SMART 报告离屏渲染为一张长图 PNG，经「另存为」对话框保存。
@MainActor
private enum SMARTReportExporter {
    static func export(_ report: ReportDTO) {
        let renderer = ImageRenderer(
            content: ReportImageContent(report: report)
                .environment(\.colorScheme, .light)   // 固定浅色：深色模式下导出的图也可读
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 760, height: nil)
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName(report)
        panel.message = "选择保存位置（导出为一张长图 PNG）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }

    private static func suggestedFileName(_ report: ReportDTO) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let disk = report.device.label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "DitKit_SMART健康报告_\(disk)_\(f.string(from: Date())).png"
    }
}

/// 报告的整页渲染视图（白底长图，独立于屏幕 UI）。
private struct ReportImageContent: View {
    let report: ReportDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DitKit · SMART 健康报告")
                    .font(.system(size: 24, weight: .semibold))
                Text("\(report.device.label) · 生成时间：\(report.generatedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            summary
            ForEach(report.sections) { section in
                SectionCard(section: section)
            }
            if !report.warnings.isEmpty {
                bullets(title: "需要留意", items: report.warnings, color: .orange)
            }
            if !report.messages.isEmpty {
                bullets(title: "工具提示（已翻译为中文）", items: report.messages, color: .secondary)
            }
            bullets(title: "命令退出码 \(report.exitCode) 说明", items: report.exitNotes, color: .secondary)
            Text("本报告由 smartctl 原始 JSON 逐字段翻译生成，未改动任何数值。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 760, alignment: .leading)
        .background(Color.white)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("总体结论").font(.caption).foregroundStyle(.secondary)
                Text(report.overall).font(.system(size: 28, weight: .medium))
                StatusPill(status: report.status)
                Spacer()
            }
            Text(report.summary).font(.subheadline)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func bullets(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Text("· " + item)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
