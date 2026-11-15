import Foundation

/// 文件传输引擎：复制模式 / 同步模式的核心逻辑，纯逻辑、可单测。
///
/// 两种模式都会：
/// 1. 复制/同步文件（按 4 MiB 阈值分流，见 `FileCopier`）；
/// 2. 用所选算法（默认 xxHash128）对源与目标做哈希校验；
/// 3. 在**每个目标目录根**写入一组报告（ASC MHL v2.0 清单 + PDF 明细表）。
public enum TransferEngine {

    // MARK: - 入口

    /// 执行一次传输任务。
    /// - parameter onProgress: 非逃逸的 `@MainActor` 进度回调，供 UI 实时刷新。
    /// - parameter control: 可选的执行控制器；在文件边界支持暂停/停止，停止后只写已完成部分。
    public static func execute(
        config: TransferConfig,
        onProgress: @MainActor (TransferProgress) -> Void,
        control: RunControl? = nil
    ) async -> TransferResult {
        let started = Date()
        var result = TransferResult(startedAt: started)

        let targets = config.targets
        let progress = ProgressAccumulator(total: estimateTotal(config: config))

        do {
            switch config.mode {
            case .copy:
                result.records = try await runCopy(
                    sources: config.sources,
                    targets: targets,
                    algorithm: config.algorithm,
                    progress: progress,
                    onProgress: onProgress,
                    control: control
                )
            case .sync:
                result.records = try await runSync(
                    source: config.sources.first!,
                    targets: targets,
                    algorithm: config.algorithm,
                    progress: progress,
                    onProgress: onProgress,
                    control: control
                )
            }
        } catch {
            result.errorMessage = error.localizedDescription
        }

        result.stopped = control?.isStopped ?? false

        // 每个目标目录根写一组报告（ASC MHL v2.0 清单 + PDF 明细表）。
        // 标准 <hashes> 收录本目录内所有存在且已算过哈希的文件（复制/更新/跳过）；
        // 删除/失败等没有有效目标文件的操作，连同元信息、汇总一起写进完整明细段。
        // 停止时 records 只含已完成部分，故为部分报告。
        let reportFinished = Date()
        for target in targets {
            let rawRoot = target.path
            let resolvedRoot = target.resolvingSymlinksInPath().path
            let scoped = result.records.filter {
                isUnder($0.targetPath, root: rawRoot) || isUnder($0.targetPath, root: resolvedRoot)
            }
            let entries: [MHLReport.Entry] = scoped
                .filter { $0.action == .copied || $0.action == .updated || $0.action == .skipped }
                .map { record in
                    let mtime = try? FileManager.default.attributesOfItem(
                        atPath: record.targetPath
                    )[.modificationDate] as? Date
                    return MHLReport.Entry(
                        path: record.relativePath,
                        size: record.size >= 0 ? record.size : nil,
                        lastModificationDate: mtime,
                        algorithm: record.algorithm,
                        hashValue: record.sourceHash
                    )
                }
            let meta = transferMeta(mode: config.mode, algorithm: config.algorithm,
                                    target: target, startedAt: started,
                                    finishedAt: reportFinished, stopped: result.stopped)
            let summary = transferSummary(records: scoped, stopped: result.stopped)
            let detail = MHLReportDetail(
                meta: meta, summary: summary,
                records: scoped.map { record in
                    MHLReportDetail.Record(
                        action: record.action.rawValue,
                        path: record.relativePath,
                        size: record.size >= 0 ? record.size : nil,
                        algorithm: record.algorithm,
                        sourceHash: record.sourceHash,
                        targetHash: record.targetHash,
                        verify: record.action == .deleted ? "—" : (record.verified ? "一致" : "不一致"),
                        note: record.note,
                        sourcePath: record.sourcePath.isEmpty ? nil : record.sourcePath,
                        targetPath: record.targetPath.isEmpty ? nil : record.targetPath
                    )
                }
            )
            guard let mhlURL = try? MHLReport.write(
                entries: entries,
                process: "transfer",
                directory: target,
                filePrefix: "DitKit_传输报告_\(config.mode.rawValue)_\(config.algorithm.tag)",
                startedAt: started,
                finishedAt: reportFinished,
                detail: detail
            ) else { continue }
            result.reportURLs.append(mhlURL)

            // 同目录根写一份配套 PDF（人类可读的完整明细表），与 MHL 明细段同源。
            if let pdfURL = try? writeTransferPDF(
                records: scoped, mode: config.mode, algorithm: config.algorithm,
                target: target, mhlURL: mhlURL, startedAt: started,
                finishedAt: reportFinished, stopped: result.stopped
            ) {
                result.reportURLs.append(pdfURL)
            }
        }

        result.finishedAt = Date()
        let finalProgress = progress.snapshot(phase: result.stopped ? "已停止" : "完成")
        await onProgress(finalProgress)
        return result
    }

    // MARK: - PDF 报告

    /// 为单个目标目录生成 PDF 报告（与 `.mhl` 同名，扩展名 `.pdf`）。
    private static func writeTransferPDF(
        records: [TransferRecord],
        mode: TransferMode,
        algorithm: HashAlgorithm,
        target: URL,
        mhlURL: URL,
        startedAt: Date,
        finishedAt: Date,
        stopped: Bool = false
    ) throws -> URL {
        let pdfURL = mhlURL.deletingPathExtension().appendingPathExtension("pdf")
        let columns: [PDFReport.Column] = [
            .init(name: "操作", width: 48),
            .init(name: "相对路径", width: 0),
            .init(name: "大小", width: 58),
            .init(name: "哈希", width: 138, monospace: true),
            .init(name: "校验", width: 50),
        ]
        let rows = records.map { r -> PDFReport.Row in
            // 三色规则：复制/更新=绿、跳过=灰、删除=红；异常（校验不一致/失败）优先红。
            let color: PDFReport.RowColor
            switch r.action {
            case .copied, .updated: color = r.verified ? .good : .bad
            case .skipped: color = r.verified ? .muted : .bad
            case .deleted, .failed: color = .bad
            }
            let verify: String
            if r.action == .deleted {
                verify = "—"
            } else {
                verify = r.verified ? "一致" : "不一致"
            }
            let hash = r.sourceHash.isEmpty ? "—" : r.sourceHash
            return PDFReport.Row(
                [r.action.rawValue, r.relativePath, PDFReport.byteString(r.size), hash, verify],
                color: color
            )
        }
        try PDFReport.write(
            title: "DitKit 传输报告",
            meta: transferMeta(mode: mode, algorithm: algorithm, target: target,
                               startedAt: startedAt, finishedAt: finishedAt, stopped: stopped),
            summary: transferSummary(records: records, stopped: stopped),
            columns: columns,
            rows: rows,
            to: pdfURL
        )
        return pdfURL
    }

    /// 报告元信息与汇总：MHL 明细段与 PDF 共用，保证两份报告信息完全一致。
    private static func transferMeta(
        mode: TransferMode,
        algorithm: HashAlgorithm,
        target: URL,
        startedAt: Date,
        finishedAt: Date,
        stopped: Bool
    ) -> [String] {
        var meta = [
            "模式：\(mode.rawValue)",
            "校验算法：\(algorithm.rawValue)",
            "目标目录：\(target.path)",
            "开始时间：\(PDFReport.readable(startedAt))",
            "结束时间：\(PDFReport.readable(finishedAt))",
        ]
        if stopped { meta.append("状态：已停止（部分报告，仅含本次已完成的记录）") }
        return meta
    }

    private static func transferSummary(records: [TransferRecord], stopped: Bool) -> [String] {
        let counts = TransferResult(records: records)
        var summary = [
            "复制 \(counts.copied) · 更新 \(counts.updated) · 跳过 \(counts.skipped) · 删除 \(counts.deleted) · 失败 \(counts.failed) · 校验通过 \(counts.verifiedOK)"
        ]
        if stopped { summary.append("本次任务被用户停止，未处理的文件不在清单内") }
        return summary
    }

    // MARK: - 复制模式

    /// 展开来源为「(源文件, 目标相对路径)」列表：
    /// - 文件 → 直接以其文件名落入目标；
    /// - 恰好一个文件夹 → 扁平化：把其**内容**直接落入目标；
    /// - 多个文件夹 → 保留各自文件夹名，整体落入目标。
    static func expandSources(_ sources: [URL]) -> [(url: URL, rel: String)] {
        let folders = sources.filter { FileCopier.isDirectory($0) }
        let files = sources.filter { !FileCopier.isDirectory($0) }
        var entries: [(URL, String)] = []
        for f in files { entries.append((f, f.lastPathComponent)) }

        if folders.count <= 1 {
            for d in folders {
                for (rel, u) in walkFiles(in: d, base: d) {
                    entries.append((u, rel))
                }
            }
        } else {
            for d in folders {
                for (rel, u) in walkFiles(in: d, base: d) {
                    entries.append((u, d.lastPathComponent + "/" + rel))
                }
            }
        }
        return entries
    }

    private static func runCopy(
        sources: [URL],
        targets: [URL],
        algorithm: HashAlgorithm,
        progress: ProgressAccumulator,
        onProgress: @MainActor (TransferProgress) -> Void,
        control: RunControl?
    ) async throws -> [TransferRecord] {
        let entries = expandSources(sources)
        var records: [TransferRecord] = []
        let fm = FileManager.default

        targetLoop: for target in targets {
            guard await shouldContinue(control) else { break targetLoop }
            try ensureDir(target)
            for entry in entries {
                // 文件边界：暂停时等待，停止时立即收尾（当前文件不会被打断）。
                guard await shouldContinue(control) else { break targetLoop }
                let targetURL = target.appendingPathComponent(entry.rel)
                try ensureDir(targetURL.deletingLastPathComponent())

                let exists = fm.fileExists(atPath: targetURL.path)
                let sameSize = exists && FileCopier.fileSize(targetURL) == FileCopier.fileSize(entry.url)

                if exists, sameSize {
                    // 大小一致 → 再做内容级哈希校验：一致才跳过，不一致则重新复制更新。
                    let sourceHash = try await FileHasher.hash(fileAt: entry.url, algorithm: algorithm).value
                    let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                    if sourceHash == targetHash {
                        records.append(.init(
                            action: .skipped, relativePath: entry.rel,
                            sourcePath: entry.url.path, targetPath: targetURL.path,
                            size: FileCopier.fileSize(entry.url), algorithm: algorithm.tag,
                            sourceHash: sourceHash, targetHash: targetHash, verified: true,
                            note: "目标已存在，哈希校验一致，跳过"
                        ))
                        progress.done(current: entry.rel)
                        await onProgress(progress.snapshot(phase: "复制中"))
                        continue
                    }
                    // 哈希不一致：落入下方更新路径（exists → remove + 重新复制）。
                }

                if exists { try? fm.removeItem(at: targetURL) }

                let (size, sourceHash) = try await FileCopier.copyAndHashSource(entry.url, to: targetURL, algorithm: algorithm)
                let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                let verified = (sourceHash == targetHash)
                let action: TransferAction = exists ? .updated : .copied
                records.append(.init(
                    action: action, relativePath: entry.rel,
                    sourcePath: entry.url.path, targetPath: targetURL.path,
                    size: size, algorithm: algorithm.tag,
                    sourceHash: sourceHash, targetHash: targetHash,
                    verified: verified,
                    note: verified ? "" : "校验失败：源与目标哈希不一致"
                ))
                progress.done(current: entry.rel)
                await onProgress(progress.snapshot(phase: "复制中"))
            }
        }
        return records
    }

    // MARK: - 同步模式（目标完全对齐源）

    private static func runSync(
        source: URL,
        targets: [URL],
        algorithm: HashAlgorithm,
        progress: ProgressAccumulator,
        onProgress: @MainActor (TransferProgress) -> Void,
        control: RunControl?
    ) async throws -> [TransferRecord] {
        let fm = FileManager.default
        var records: [TransferRecord] = []

        // 1) 遍历源，得到全部文件/目录的相对路径（对所有目标共用）。
        let sourceAll = walkAll(in: source, base: source)      // [(rel, url, isDir)]
        let sourceFiles = sourceAll.filter { !$0.isDir }
        let sourceFileRels = Set(sourceFiles.map { $0.rel })
        let sourceDirRels = Set(sourceAll.filter { $0.isDir }.map { $0.rel })

        // 2) 对每个目标目录独立执行「少补 + 清理多余项」，最终完全对齐源。
        targetLoop: for target in targets {
            guard await shouldContinue(control) else { break targetLoop }
            try ensureDir(target)

            // 少补：复制/更新/跳过，让该目标对齐源。
            for item in sourceFiles {
                // 文件边界：暂停时等待，停止时立即收尾（当前文件不会被打断）。
                guard await shouldContinue(control) else { break targetLoop }
                let targetURL = target.appendingPathComponent(item.rel)
                try ensureDir(targetURL.deletingLastPathComponent())
                let exists = fm.fileExists(atPath: targetURL.path)
                let sameSize = exists && FileCopier.fileSize(targetURL) == FileCopier.fileSize(item.url)

                if exists, sameSize {
                    // 大小一致 → 再做内容级哈希校验：一致才跳过，不一致则重新同步更新。
                    let sourceHash = try await FileHasher.hash(fileAt: item.url, algorithm: algorithm).value
                    let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                    if sourceHash == targetHash {
                        records.append(.init(
                            action: .skipped, relativePath: item.rel,
                            sourcePath: item.url.path, targetPath: targetURL.path,
                            size: FileCopier.fileSize(item.url), algorithm: algorithm.tag,
                            sourceHash: sourceHash, targetHash: targetHash, verified: true,
                            note: "目标已存在，哈希校验一致，跳过"
                        ))
                        progress.done(current: item.rel)
                        await onProgress(progress.snapshot(phase: "同步中"))
                        continue
                    }
                    // 哈希不一致：落入下方更新路径（exists → remove + 重新复制）。
                }

                if exists { try? fm.removeItem(at: targetURL) }
                let (size, sourceHash) = try await FileCopier.copyAndHashSource(item.url, to: targetURL, algorithm: algorithm)
                let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                let verified = (sourceHash == targetHash)
                let action: TransferAction = exists ? .updated : .copied
                records.append(.init(
                    action: action, relativePath: item.rel,
                    sourcePath: item.url.path, targetPath: targetURL.path,
                    size: size, algorithm: algorithm.tag,
                    sourceHash: sourceHash, targetHash: targetHash,
                    verified: verified,
                    note: verified ? "" : "校验失败：源与目标哈希不一致"
                ))
                progress.done(current: item.rel)
                await onProgress(progress.snapshot(phase: "同步中"))
            }

            // 多删：删除该目标中源没有的项。
            let targetAll = walkAll(in: target, base: target)
            let extraDirSet = Set(targetAll.filter { $0.isDir && !sourceDirRels.contains($0.rel) }.map { $0.rel })

            for entry in targetAll {
                // 删除也是逐项操作，同样在文件（条目）边界响应暂停/停止。
                guard await shouldContinue(control) else { break targetLoop }
                if entry.isDir {
                    if !sourceDirRels.contains(entry.rel) {
                        try? fm.removeItem(at: entry.url)
                        records.append(.init(
                            action: .deleted, relativePath: entry.rel,
                            sourcePath: "", targetPath: target.appendingPathComponent(entry.rel).path,
                            size: 0, algorithm: algorithm.tag,
                            sourceHash: "", targetHash: "", verified: false,
                            note: "目标多余目录，已删除"
                        ))
                        progress.done(current: entry.rel)
                        await onProgress(progress.snapshot(phase: "清理多余项中"))
                    }
                } else {
                    if !sourceFileRels.contains(entry.rel) {
                        // DitKit 自己生成的报告文件（.mhl/.pdf）不算多余项，不删。
                        if isReportFile(entry.url) { continue }
                        // 若其父目录本身就是要被整棵删除的多余目录，则跳过（已随父目录删除）。
                        let parentRel = (entry.rel as NSString).deletingLastPathComponent
                        if parentRel.isEmpty || !extraDirSet.contains(parentRel) {
                            try? fm.removeItem(at: entry.url)
                            records.append(.init(
                                action: .deleted, relativePath: entry.rel,
                                sourcePath: "", targetPath: target.appendingPathComponent(entry.rel).path,
                                size: FileCopier.fileSize(entry.url), algorithm: algorithm.tag,
                                sourceHash: "", targetHash: "", verified: false,
                                note: "目标多余文件，已删除"
                            ))
                            progress.done(current: entry.rel)
                            await onProgress(progress.snapshot(phase: "清理多余项中"))
                        }
                    }
                }
            }
        }

        return records
    }

    // MARK: - 目录遍历与工具

    /// 递归列出目录下所有**文件**，返回相对 `base` 的路径。
    ///
    /// `base` 与子项可能因 `/var`↔`/private/var` 符号链接而形式不同，
    /// 因此用「符号链接解析 + 组件比对」计算相对路径，避免字符串前缀截断出错。
    static func walkFiles(in dir: URL, base: URL) -> [(rel: String, url: URL)] {
        let basePath = base.resolvingSymlinksInPath().path
        return walkFiles(in: dir, basePath: basePath)
    }

    private static func walkFiles(in dir: URL, basePath: String) -> [(rel: String, url: URL)] {
        var result: [(String, URL)] = []
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return result }
        for child in children {
            let rv = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = rv?.isDirectory ?? false
            let isSymlink = rv?.isSymbolicLink ?? false
            let rel = relativePath(of: child, relativeToBasePath: basePath)
            if isDir, !isSymlink {
                result.append(contentsOf: walkFiles(in: child, basePath: basePath))
            } else {
                result.append((rel, child))
            }
        }
        return result
    }

    /// 递归列出目录下所有条目（含目录），返回相对 `base` 的路径与是否目录。
    static func walkAll(in dir: URL, base: URL) -> [(rel: String, url: URL, isDir: Bool)] {
        let basePath = base.resolvingSymlinksInPath().path
        return walkAll(in: dir, basePath: basePath)
    }

    private static func walkAll(in dir: URL, basePath: String) -> [(rel: String, url: URL, isDir: Bool)] {
        var result: [(String, URL, Bool)] = []
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return result }
        for child in children {
            let rv = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = rv?.isDirectory ?? false
            let isSymlink = rv?.isSymbolicLink ?? false
            let rel = relativePath(of: child, relativeToBasePath: basePath)
            if isDir, !isSymlink {
                result.append((rel, child, true))
                result.append(contentsOf: walkAll(in: child, basePath: basePath))
            } else {
                result.append((rel, child, false))
            }
        }
        return result
    }

    /// 计算 `child` 相对 `basePath` 的相对路径，稳健处理 `/private` 等符号链接差异。
    private static func relativePath(of child: URL, relativeToBasePath basePath: String) -> String {
        let childPath = child.resolvingSymlinksInPath().path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if childPath.hasPrefix(prefix) {
            let rel = String(childPath.dropFirst(prefix.count))
            return rel.isEmpty ? child.lastPathComponent : rel
        }
        // 兜底：逐组件比对（应对 /private 等符号链接差异）。
        let baseComps = basePath.split(separator: "/", omittingEmptySubsequences: false)
        let childComps = childPath.split(separator: "/", omittingEmptySubsequences: false)
        guard childComps.count >= baseComps.count else { return child.lastPathComponent }
        for i in 0..<baseComps.count where baseComps[i] != childComps[i] {
            return child.lastPathComponent
        }
        let relComps = Array(childComps.dropFirst(baseComps.count))
        return relComps.isEmpty ? child.lastPathComponent : relComps.joined(separator: "/")
    }

    /// 文件边界的统一检查点：未传控制器时永远继续。
    private static func shouldContinue(_ control: RunControl?) async -> Bool {
        guard let control else { return true }
        return await control.gate()
    }

    /// 判断文件路径是否属于某个目标根，兼容 `/var` ↔ `/private/var` 等符号链接形式差异。
    private static func isUnder(_ path: String, root: String) -> Bool {
        if path == root || path.hasPrefix(root + "/") { return true }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 是否为 DitKit 生成报告文件（同步的「多删」阶段要保护它们）。
    private static func isReportFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("DitKit_") else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "mhl" || ext == "pdf"
    }

    static func estimateTotal(config: TransferConfig) -> Int {
        switch config.mode {
        case .copy:
            return max(1, expandSources(config.sources).count * config.targets.count)
        case .sync:
            return max(1, walkFiles(in: config.sources.first!, base: config.sources.first!).count * config.targets.count)
        }
    }
}

/// 进度累加器：在传输引擎内部累积计数，按需生成 `TransferProgress` 快照。
private final class ProgressAccumulator {
    var doneCount: Int
    let total: Int
    var current: String

    init(total: Int) {
        self.doneCount = 0
        self.total = total
        self.current = ""
    }

    func done(current: String) {
        doneCount += 1
        self.current = current
    }

    func snapshot(phase: String) -> TransferProgress {
        TransferProgress(
            filesDone: doneCount, filesTotal: total,
            currentFile: (current as NSString).lastPathComponent,
            bytesDone: 0, bytesTotal: 0, phase: phase
        )
    }
}
