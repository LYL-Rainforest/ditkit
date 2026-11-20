import SwiftUI
import AppKit
import DitKitCore

/// 第四个标签页：选择文件/目录 → 读 EXIF → 预览新文件名 → 原地批量重命名。
struct RenameView: View {
    @State private var controller = RenameController()
    @State private var customText = ""

    var body: some View {
        VStack(spacing: 12) {
            controlBar
            if controller.isBusy { runProgressSection }
            formatHint
            pickerZone
            ReportPlacementSection(placement: $controller.reportPlacement,
                                   isDisabled: controller.isBusy,
                                   alongsideHint: "原文件所在目录")
            if !controller.inputs.isEmpty { inputList }
            if !controller.items.isEmpty { listHeader }
            listArea
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: customText) { _, _ in controller.invalidatePreview() }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            TextField("自定义文本（可留空）", text: $customText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(controller.isBusy)
            Button("选择文件或文件夹") { controller.chooseFilesOrFolders() }
                .disabled(controller.isBusy)
            Button("清空") { controller.clear() }
                .disabled(controller.inputs.isEmpty || controller.isBusy)
            Spacer(minLength: 8)
            if controller.isBusy {
                ProgressView().controlSize(.small)
                Button(controller.isPaused ? "继续" : "暂停") { controller.pauseOrResume() }
                Button("停止", role: .destructive) { controller.stop() }
            }
            Button("生成预览") {
                Task { await controller.scan(custom: customText) }
            }
            .disabled(!controller.canPreview)
            Button(controller.phase == .stopped ? "继续重命名" : "执行重命名") {
                Task { await controller.apply() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canApply)
        }
    }

    private var runProgressSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: Double(controller.runProgress.done),
                         total: Double(max(1, controller.runProgress.total)))
            Text("\(controller.isPaused ? "已暂停" : "处理中") · \(controller.runProgress.done)/\(controller.runProgress.total) · \(controller.runProgress.currentFile)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var formatHint: some View {
        Text("格式：年月日_时分秒_毫秒三位_自定义.扩展名 · 时间取 EXIF 拍摄时间（缺失用文件时间）；毫秒取 EXIF 子秒，两位补 0，缺失用系统时间")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 点击弹出选择面板；也可把文件 / 文件夹从 Finder 直接拖进来（AppKit 原生拖拽）。
    private var pickerZone: some View {
        FileDropZone(
            filter: .filesAndFolders,
            isDisabled: controller.isBusy,
            minHeight: 84,
            onTap: { controller.chooseFilesOrFolders() },
            onDrop: { urls in controller.add(urls) }
        ) {
            VStack(spacing: 6) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                Text("点击选择，或把文件 / 文件夹拖到这里（自动递归子目录）")
                    .font(.system(size: 13, weight: .medium))
                Text(controller.inputs.isEmpty ? "尚未添加内容" : "已添加 \(controller.inputs.count) 项，见下方列表")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 输入项列表

    /// 与「文件传输」的来源列表一致：图标 + 名称 + 类型 + 单项移除。
    private var inputList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(controller.inputs.enumerated()), id: \.element) { index, url in
                    inputRow(url, index: index)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 130)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func inputRow(_ url: URL, index: Int) -> some View {
        let directory = FileCopier.isDirectory(url)
        return HStack(spacing: 8) {
            Image(systemName: directory ? "folder" : (RenamePlanner.isVideo(url) ? "film" : "photo"))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(directory ? "文件夹" : "文件")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                Task { await controller.removeInputAndRescan(at: index, custom: customText) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .help(url.path)
    }

    private var listHeader: some View {
        HStack {
            Text("原文件 / EXIF 信息").font(.caption.weight(.semibold))
            Spacer()
            Text("新文件名 / 状态").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    private var listArea: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(controller.items) { item in
                    row(item)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ item: RenameItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: RenamePlanner.isVideo(item.url) ? "film" : "photo")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.originalName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(detailText(item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 280, alignment: .leading)
            Spacer(minLength: 8)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(item.proposedName)
                .font(.system(size: 12.5, weight: .medium))
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(minWidth: 220, alignment: .leading)
            Text(item.state.label)
                .font(.caption2)
                .foregroundStyle(stateColor(item.state))
                .frame(width: 100, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.message)
                .font(.caption)
                .foregroundStyle(messageColor)
            ForEach(controller.reportURLs, id: \.self) { url in
                Text("报告：\(url.path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            ForEach((controller.outcome?.messages ?? []).prefix(3), id: \.self) { detail in
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 交互

    private func detailText(_ item: RenameItem) -> String {
        var parts = [item.parentName, item.captureDateText, "毫秒 \(item.millisecond)（\(item.millisecondSource.rawValue)）"]
        if let model = item.capture?.cameraModel, !model.isEmpty {
            parts.append("相机 \(model)")
        }
        return parts.joined(separator: " · ")
    }

    private func stateColor(_ state: RenameItemState) -> Color {
        switch state {
        case .renamed: return .green
        case .failed: return .red
        case .skipped: return .orange
        case .pending, .unchanged: return .secondary
        }
    }

    private var messageColor: Color {
        switch controller.phase {
        case .failed: return .red
        case .applied: return .green
        case .paused, .stopped: return .orange
        default: return .secondary
        }
    }
}
