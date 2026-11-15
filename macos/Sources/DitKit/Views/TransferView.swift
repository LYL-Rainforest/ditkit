import SwiftUI
import AppKit
import DitKitCore

/// 文件传输标签页：复制模式 / 同步模式。
struct TransferView: View {
    @State private var controller = TransferController()
    /// 当前被拖拽悬停的目标框序号，用于单独高亮。
    @State private var targetedTarget: Int?

    /// 目标目录数量：两种模式均支持 1~3 个（界面显示 3 个框，至少填 1 个）。
    private var targetCount: Int { 3 }

    var body: some View {
        VStack(spacing: 12) {
            controlBar
            sourceSection
            targetSection
            if controller.isRunning { progressSection }
            resultSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: controller.mode) { _, _ in controller.resetForMode() }
        .alert("确认同步（将删除目标中的多余项）", isPresented: $controller.syncConfirmRequested) {
            Button("取消", role: .cancel) { controller.cancelSync() }
            Button("确认同步", role: .destructive) { controller.confirmSync() }
        } message: {
            Text("同步模式会让每个目标目录完全对齐源目录：源没有的文件/文件夹会从各目标中删除。此操作不可逆。")
        }
    }

    // MARK: - 顶部控制条

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("模式", selection: $controller.mode) {
                ForEach(TransferMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Picker("校验", selection: $controller.algorithm) {
                ForEach(HashAlgorithm.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer(minLength: 8)

            if controller.isRunning {
                ProgressView().controlSize(.small)
                Button(controller.isPaused ? "继续" : "暂停") { controller.pauseOrResume() }
                Button("停止", role: .destructive) { controller.stop() }
            }
            Button("清空") { controller.resetForMode() }
                .disabled(controller.isRunning)
            Button("开始传输") { controller.run() }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canRun)
        }
    }

    // MARK: - 来源

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.mode == .copy ? "来源（文件或文件夹，可多个）" : "来源（仅一个目录）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            sourcePickerZone
            if !controller.sources.isEmpty {
                HStack(spacing: 10) {
                    Text("已添加 \(controller.sources.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重新选择") { controller.chooseSources() }
                        .disabled(controller.isRunning)
                }
                sourceList
            }
        }
    }

    /// 点击弹出选择面板；也可把文件 / 文件夹从 Finder 直接拖进来（AppKit 原生拖拽）。
    private var sourcePickerZone: some View {
        FileDropZone(
            filter: controller.mode == .copy ? .filesAndFolders : .directoriesOnly,
            isDisabled: controller.isRunning,
            minHeight: 78,
            onTap: { controller.chooseSources() },
            onDrop: { urls in
                if controller.mode == .copy {
                    controller.addSources(urls)
                } else if let first = urls.first {
                    controller.setSyncSource(first)
                }
            }
        ) {
            VStack(spacing: 6) {
                Image(systemName: controller.mode == .copy ? "tray.and.arrow.up" : "folder.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                Text(controller.mode == .copy
                     ? "点击选择，或把文件 / 文件夹拖到这里（可多个）"
                     : "点击选择，或把一个目录拖到这里作为同步源")
                    .font(.system(size: 13, weight: .medium))
                Text(controller.sources.isEmpty ? "尚未添加来源" : "已添加 \(controller.sources.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(controller.sources.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 8) {
                        Image(systemName: FileCopier.isDirectory(url) ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(FileCopier.isDirectory(url) ? "文件夹" : "文件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            controller.removeSource(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.isRunning)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 130)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 目标

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("目标目录（1~3 个）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("· 点击选目录，或把目录拖到右侧小框；拖多个会依次填入")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(0..<targetCount, id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField("目标目录 \(i + 1) 路径",
                                  text: $controller.targetStrings[i])
                            .textFieldStyle(.roundedBorder)
                        targetDropButton(i)
                        if !controller.targetStrings[i].isEmpty {
                            Button {
                                controller.clearTarget(i)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(controller.isRunning)
                        }
                    }
                }
            }
        }
    }

    /// 每个目标行独立的可点击 / 可拖入区域。只覆盖这一小块，不遮挡左侧可编辑的路径输入框。
    private func targetDropButton(_ index: Int) -> some View {
        let active = targetedTarget == index
        return HStack(spacing: 4) {
            Image(systemName: active ? "folder.fill.badge.plus" : "folder.badge.plus")
                .font(.caption)
            Text(active ? "松开填入" : "选择 / 拖入")
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 112, height: 24)
        .background(
            active ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(active ? 0.9 : 0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .overlay(
            FileDropReceiver(
                filter: .directoriesOnly,
                isDisabled: controller.isRunning,
                onHighlight: { highlighted in
                    if highlighted {
                        targetedTarget = index
                    } else if targetedTarget == index {
                        targetedTarget = nil
                    }
                },
                onTap: { controller.chooseTarget(index) },
                onDrop: { urls in controller.setTargets(startingAt: index, urls) }
            )
        )
        .opacity(controller.isRunning ? 0.55 : 1)
    }

    // MARK: - 进度

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(controller.progress.filesDone),
                         total: Double(max(1, controller.progress.filesTotal)))
            Text("\(controller.progress.phase) · \(controller.progress.filesDone)/\(controller.progress.filesTotal) · \(controller.progress.currentFile)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.message)
                .font(.caption)
                .foregroundStyle(messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let result = controller.result, !result.records.isEmpty {
                HStack {
                    Text("传输明细（\(result.records.count) 条）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !result.reportURLs.isEmpty {
                        Text("报告已写入目标目录根")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                recordList(result.records)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func recordList(_ records: [TransferRecord]) -> some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(records, id: \.id) { r in
                    recordRow(r)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 220)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func recordRow(_ r: TransferRecord) -> some View {
        HStack(spacing: 8) {
            Text(r.action.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(actionColor(r.action))
                .frame(width: 44, alignment: .leading)
            Text(r.relativePath)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            if r.size >= 0 {
                Text(byteString(r.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
            Text(r.action == .deleted ? "—" : (r.verified ? "✓" : "✗"))
                .font(.caption2)
                .foregroundStyle(r.action == .deleted ? Color.secondary : (r.verified ? Color.green : Color.red))
                .frame(width: 22, alignment: .center)
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func byteString(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var messageColor: Color {
        switch controller.phase {
        case .failed: return .red
        case .done: return .green
        case .paused, .stopped: return .orange
        default: return .secondary
        }
    }

    private func actionColor(_ action: TransferAction) -> Color {
        switch action {
        case .copied: return .blue
        case .updated: return .orange
        case .skipped: return .secondary
        case .deleted: return .red
        case .failed: return .red
        }
    }
}
