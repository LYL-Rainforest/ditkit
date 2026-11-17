import Foundation
import AppKit
import Observation
import DitKitCore

/// 「EXIF 重命名」页的状态机。文件遍历/命名逻辑都在 DitKitCore/Rename，这里只管交互。
/// 扫描与执行都支持「暂停 / 继续 / 停止」；停止后保留已完成的部分结果并写部分报告。
@MainActor
@Observable
final class RenameController {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case applying
        case paused
        case stopped
        case applied
        case failed(String)
    }

    struct RunProgress: Equatable {
        var done: Int = 0
        var total: Int = 0
        var currentFile: String = ""
    }

    var inputs: [URL] = []
    var items: [RenameItem] = []
    var phase: Phase = .idle
    var message = "点击选择文件或文件夹"
    var outcome: RenameOutcome?
    var reportURLs: [URL] = []
    var runProgress = RunProgress()

    @ObservationIgnored private var control = RunControl()
    @ObservationIgnored private var pausedFrom: Phase = .scanning

    /// 任务进行中（含暂停），期间禁止改输入、重新预览或重复执行。
    var isBusy: Bool { phase == .scanning || phase == .applying || phase == .paused }
    var isPaused: Bool { phase == .paused }
    var canPreview: Bool { !inputs.isEmpty && !isBusy }
    /// 停止后允许对剩余 `.pending` 项继续执行。
    var canApply: Bool {
        guard !isBusy else { return false }
        return (phase == .ready || phase == .stopped) && items.contains { $0.state == .pending }
    }

    private var stageName: String { pausedFrom == .scanning ? "读取 EXIF" : "重命名" }

    func add(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        var seen = Set(inputs.map { $0.standardizedFileURL.path })
        for url in urls {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                inputs.append(standardized)
            }
        }
        invalidatePreview()
        message = "已添加 \(inputs.count) 个输入项（目录会自动递归子目录），点击「生成预览」"
    }

    func clear() {
        guard !isBusy else { return }
        inputs.removeAll()
        invalidatePreview()
        message = "已清空，重新选择文件/文件夹"
    }

    /// 从输入项列表移除单个条目。旧预览立即失效；若仍有输入项，自动重新扫描刷新预览。
    func removeInputAndRescan(at index: Int, custom: String) async {
        guard !isBusy, inputs.indices.contains(index) else { return }
        inputs.remove(at: index)
        invalidatePreview()
        guard !inputs.isEmpty else {
            message = "已清空输入项，可重新选择或拖入文件"
            return
        }
        message = "已移除 1 项，正在重新生成预览…"
        await scan(custom: custom)
    }

    /// 改配置时旧预览立即失效，避免用过期名字执行重命名。
    /// 已经执行完成（.applied）或用户停止（.stopped）的结果要保留，尤其报告链接与明细，
    /// 否则执行后碰一下自定义输入框就会把刚生成的 MHL/PDF 全部清掉。
    func invalidatePreview() {
        guard !isBusy else { return }
        if phase == .applied || phase == .stopped {
            message = "结果已保留；修改配置后可重新生成预览，执行前请确认"
            return
        }
        items.removeAll()
        outcome = nil
        reportURLs = []
        runProgress = RunProgress()
        phase = .idle
    }

    func chooseFilesOrFolders() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "添加"
        panel.message = "可同时选择多个文件、多个文件夹；文件夹会递归处理其中的子目录。"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    // MARK: - 执行控制

    func pauseOrResume() {
        if phase == .paused {
            control.resume()
            phase = pausedFrom
            message = "已继续 · 正在\(stageName)"
        } else if phase == .scanning || phase == .applying {
            pausedFrom = phase
            control.pause()
            phase = .paused
            message = "已暂停 · 当前文件处理完后停住，点「继续」恢复"
        }
    }

    func stop() {
        guard isBusy else { return }
        control.stop()
        message = "正在停止（等待当前文件完成，随后只对已完成项生成部分报告）…"
    }

    // MARK: - 扫描预览

    func scan(custom: String) async {
        guard canPreview else { return }
        control = RunControl()
        pausedFrom = .scanning
        phase = .scanning
        message = "正在读取 EXIF 并生成预览…"
        runProgress = RunProgress()
        let files = RenamePlanner.expand(inputs)
        guard !files.isEmpty else {
            phase = .failed("没有找到支持的图片或视频文件")
            message = "没有找到支持的图片或视频文件（支持 jpg/heic/raw/mov/mp4 等）"
            return
        }
        let onProgress: @MainActor (Int, Int) -> Void = { [weak self] done, total in
            guard let self else { return }
            self.runProgress = RunProgress(done: done, total: total, currentFile: "读取 EXIF")
        }
        let scanned = await RenamePlanner.previewControlled(
            for: files, custom: custom, control: control, onProgress: onProgress
        )
        if scanned.stopped {
            items.removeAll()
            outcome = nil
            reportURLs = []
            phase = .stopped
            message = "已停止扫描 · 未生成预览，可重新点击「生成预览」"
            return
        }
        items = scanned.items
        phase = .ready
        message = "共 \(scanned.items.count) 个文件 · 确认下方新文件名后点击「执行重命名」"
    }

    // MARK: - 执行重命名

    func apply() async {
        guard canApply else { return }
        control = RunControl()
        pausedFrom = .applying
        phase = .applying
        let startedAt = Date()
        runProgress = RunProgress(total: items.count)
        let onProgress: @MainActor (Int, Int, String) -> Void = { [weak self] done, total, name in
            guard let self else { return }
            self.runProgress = RunProgress(done: done, total: total, currentFile: name)
        }
        let (result, updated) = await RenamePlanner.apply(
            items, control: control, onProgress: onProgress
        )
        items = updated
        outcome = result
        let stopped = control.isStopped
        message = (stopped ? "已停止 · " : "") +
            "已重命名 \(result.renamed) 个 · 无需改动 \(result.unchanged) 个 · 失败 \(result.failed) 个"
        // 每个实际产生改动的目录根各写一组 ASC MHL v2.0 + PDF；停止时只列已完成项。
        do {
            reportURLs = try await RenameMHL.write(
                items: updated,
                startedAt: startedAt,
                finishedAt: Date(),
                onlyCompleted: stopped,
                statusNote: stopped ? "已停止（部分报告，未处理项保留原文件名）" : nil,
                allowEmpty: stopped
            )
            if !reportURLs.isEmpty {
                message += " · 已生成 \(reportURLs.count) 个报告文件（MHL 清单 + PDF）"
            }
        } catch {
            message += " · 报告生成失败：\(error.localizedDescription)"
        }
        phase = stopped ? .stopped : .applied
    }
}
