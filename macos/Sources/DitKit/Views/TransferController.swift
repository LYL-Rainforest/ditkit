import Foundation
import AppKit
import Observation
import DitKitCore

/// 「文件传输」页状态机。
/// - 复制模式：来源支持选择多个文件或文件夹；目标 1~3 个目录。
/// - 同步模式：来源仅一个目录；目标 1~3 个目录（各自独立对齐源）。
/// - 执行期间支持「暂停 / 继续 / 停止」；停止后保留已完成文件并写部分报告。
@MainActor
@Observable
final class TransferController {
    enum Phase: Equatable {
        case idle
        case running
        case paused
        case stopped
        case done
        case failed(String)
    }

    var mode: TransferMode = .copy
    var algorithm: HashAlgorithm = .xxHash128
    var sources: [URL] = []                 // 复制：多个；同步：恰好一个目录
    var targetStrings: [String] = ["", "", ""]   // 最多三个目标目录路径
    var phase: Phase = .idle
    var progress = TransferProgress()
    var result: TransferResult?
    var message = "选择来源，并至少填写一个目标目录"
    var syncConfirmRequested = false

    @ObservationIgnored private var control = RunControl()
    /// 从点击启动到 perform() 真正把 phase 置为 .running 之间存在调度窗口；
    /// 这个标志在同一同步调用栈里立即占位，杜绝快速双击跑出两个并发任务。
    @ObservationIgnored private var launchGuard = false

    /// 任务仍活着（含暂停），期间禁止改配置或重复启动。
    var isRunning: Bool { phase == .running || phase == .paused }
    var isPaused: Bool { phase == .paused }

    var canRun: Bool {
        guard !isRunning, !launchGuard else { return false }
        if mode == .copy {
            guard !sources.isEmpty else { return false }
            return targetStrings.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else {
            guard sources.count == 1, FileCopier.isDirectory(sources[0]) else { return false }
            return targetStrings.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    // MARK: - 来源

    func addSources(_ urls: [URL]) {
        guard mode == .copy, !isRunning else { return }
        var seen = Set(sources.map { $0.standardizedFileURL.path })
        for u in urls {
            let s = u.standardizedFileURL
            if seen.insert(s.path).inserted { sources.append(s) }
        }
        message = "已添加 \(sources.count) 个来源（文件直接复制；单文件夹扁平化；多文件夹整体保留）"
    }

    func setSyncSource(_ url: URL) {
        guard !isRunning else { return }
        let u = url.standardizedFileURL
        if FileCopier.isDirectory(u) {
            sources = [u]
            message = "同步来源目录：\(u.lastPathComponent)"
        } else {
            message = "同步模式只支持选择一个目录"
        }
    }

    func removeSource(at index: Int) {
        guard !isRunning, sources.indices.contains(index) else { return }
        sources.remove(at: index)
        if sources.isEmpty { message = "尚未添加来源" }
    }

    func chooseSources() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        if mode == .copy {
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.message = "可同时选择多个文件、多个文件夹；文件夹会按规则展开"
            panel.prompt = "添加来源"
        } else {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "同步模式：选择一个源目录"
            panel.prompt = "选择目录"
        }
        guard panel.runModal() == .OK else { return }
        if mode == .copy {
            addSources(panel.urls)
        } else if let u = panel.urls.first {
            setSyncSource(u)
        }
    }

    // MARK: - 目标

    func chooseTarget(_ index: Int) {
        guard !isRunning, targetStrings.indices.contains(index) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择目标目录（第 \(index + 1) 个）"
        panel.prompt = "选择目录"
        guard panel.runModal() == .OK, let u = panel.urls.first else { return }
        targetStrings[index] = u.path
    }

    /// 拖拽填入目标：从指定框开始依次写入，最多填满 3 个框。
    func setTargets(startingAt index: Int, _ urls: [URL]) {
        guard !isRunning, targetStrings.indices.contains(index) else { return }
        let dirs = urls.filter { FileCopier.isDirectory($0) }
        guard !dirs.isEmpty else {
            message = "目标只能是目录，拖入的项已被忽略"
            return
        }
        var slot = index
        for url in dirs where slot < targetStrings.count {
            targetStrings[slot] = url.standardizedFileURL.path
            slot += 1
        }
        let written = slot - index
        let overflow = dirs.count - written
        message = overflow > 0
            ? "已拖入 \(written) 个目标目录，另 \(overflow) 个超出 3 个上限未填入"
            : "已拖入 \(written) 个目标目录"
    }

    func clearTarget(_ index: Int) {
        guard !isRunning, targetStrings.indices.contains(index) else { return }
        targetStrings[index] = ""
    }

    // MARK: - 执行控制

    func run() {
        guard canRun else { return }
        if mode == .sync {
            syncConfirmRequested = true
            return
        }
        launchGuard = true
        Task { await perform() }
    }

    func confirmSync() {
        guard syncConfirmRequested, canRun else { return }
        syncConfirmRequested = false
        launchGuard = true
        Task { await perform() }
    }

    func cancelSync() {
        syncConfirmRequested = false
        launchGuard = false
    }

    /// 暂停 / 继续切换。控制点在文件边界，当前文件不会被打断。
    func pauseOrResume() {
        guard isRunning else { return }
        if phase == .paused {
            control.resume()
            phase = .running
            progress.phase = mode == .copy ? "复制中" : "同步中"
            message = "已继续 · 正在处理后续文件"
        } else {
            control.pause()
            phase = .paused
            progress.phase = "已暂停"
            message = "已暂停 · 当前文件处理完后停住，点「继续」恢复"
        }
    }

    /// 停止：保留已完成的文件，收尾时只写已完成部分。
    func stop() {
        guard isRunning else { return }
        control.stop()
        message = "正在停止（等待当前文件完成，随后生成部分报告）…"
        progress.phase = "正在停止…"
    }

    /// 切换模式时清空来源与目标，避免两种模式的来源/目标语义混淆。
    func resetForMode() {
        guard !isRunning else { return }
        sources.removeAll()
        targetStrings = ["", "", ""]
        result = nil
        progress = TransferProgress()
        message = mode == .copy
            ? "复制模式：选择多个文件或文件夹；目标 1~3 个目录"
            : "同步模式：选择一个源目录；目标 1~3 个目录"
    }

    private func perform() async {
        // 快照启动瞬间的配置，运行中即便界面控件被改动，本次任务也用同一份配置与统计口径。
        let runMode = mode
        let runAlgorithm = algorithm
        let runSources = sources
        control = RunControl()
        phase = .running
        launchGuard = false
        message = runMode == .copy ? "正在复制（按文件大小分流，≥4MiB 直传）…" : "正在同步…"
        let validTargets = targetStrings
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let config = TransferConfig(mode: runMode, algorithm: runAlgorithm, sources: runSources, targets: validTargets)
        let onProgress: @MainActor (TransferProgress) -> Void = { [weak self] p in
            guard let self else { return }
            var adjusted = p
            if self.phase == .paused {
                adjusted.phase = "已暂停"
            } else if self.control.isStopped {
                adjusted.phase = "正在停止…"
            }
            self.progress = adjusted
        }
        let res = await TransferEngine.execute(config: config, onProgress: onProgress, control: control)
        result = res
        launchGuard = false
        progress.phase = res.stopped ? "已停止" : "完成"
        let reportNote = res.reportURLs.first.map { "报告：\($0.lastPathComponent)" } ?? ""
        let reportErrorNote = res.reportErrors.isEmpty
            ? ""
            : "　⚠️ 报告写入失败：\(res.reportErrors.joined(separator: "；"))"
        let counts = "复制 \(res.copied) · 更新 \(res.updated) · 跳过 \(res.skipped)" +
            (runMode == .sync ? " · 删除 \(res.deleted)" : "") +
            " · 失败 \(res.failed) · 校验通过 \(res.verifiedOK)"
        if let err = res.errorMessage {
            phase = .failed(err)
            message = "传输出错：\(err)\(reportErrorNote)"
        } else if res.stopped {
            phase = .stopped
            message = "已停止 · \(counts) · 已生成部分报告　\(reportNote)\(reportErrorNote)"
        } else {
            phase = .done
            message = "完成 · \(counts)　\(reportNote)\(reportErrorNote)"
        }
    }
}
