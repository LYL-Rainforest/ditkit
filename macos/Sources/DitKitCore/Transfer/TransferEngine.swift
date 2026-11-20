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
    /// - parameter control: 可选的执行控制器；在文件边界支持暂停/停止，
    ///   ≥4 MiB 的大文件在块边界也能停止并保留断点，停止后只写已完成部分。
    public static func execute(
        config: TransferConfig,
        onProgress: @MainActor (TransferProgress) -> Void,
        control: RunControl? = nil,
        spaceEstimate: TransferSpaceEstimate? = nil
    ) async -> TransferResult {
        let started = Date()
        var result = TransferResult(startedAt: started)
        let space = spaceEstimate ?? estimateSpace(config: config)

        let targets = config.targets
        let progress = ProgressAccumulator(total: estimateTotal(config: config))
        // 用引用容器承载已完成的记录：即使中途某个文件抛错，之前完成的项也不会丢失。
        let collected = RecordBox()

        do {
            switch config.mode {
            case .copy:
                try await runCopy(
                    sources: config.sources,
                    targets: targets,
                    algorithm: config.algorithm,
                    progress: progress,
                    onProgress: onProgress,
                    control: control,
                    collected: collected
                )
            case .sync:
                guard let source = config.sources.first else {
                    result.errorMessage = "同步模式缺少源目录"
                    result.records = collected.records
                    result.finishedAt = Date()
                    await onProgress(progress.snapshot(phase: "失败"))
                    return result
                }
                try await runSync(
                    source: source,
                    targets: targets,
                    algorithm: config.algorithm,
                    progress: progress,
                    onProgress: onProgress,
                    control: control,
                    collected: collected
                )
            }
        } catch {
            let done = collected.records.count
            result.errorMessage = done > 0
                ? "\(error.localizedDescription)（任务中断，已完成 \(done) 项仍写入报告）"
                : error.localizedDescription
        }
        result.records = collected.records

        result.stopped = control?.isStopped ?? false

        // 报告写入：每个目标目录按所选位置（同目录 / 自定义目录 / 两者）各写一组报告。
        // 标准 <hashes> 收录本目录内所有存在且已算过哈希的文件（复制/更新/跳过）；
        // 删除/失败等没有有效目标文件的操作，连同元信息、汇总一起写进完整明细段。
        // 停止时 records 只含已完成部分，故为部分报告。两个位置都不选则完全不写报告。
        let reportFinished = Date()
        let placement = config.reportPlacement
        if placement.producesReports {
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
                                        finishedAt: reportFinished, stopped: result.stopped,
                                        space: space)
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
                            verify: (record.action == .deleted || record.action == .partial)
                                ? "—" : (record.verified ? "一致" : "不一致"),
                            note: record.note,
                            sourcePath: record.sourcePath.isEmpty ? nil : record.sourcePath,
                            targetPath: record.targetPath.isEmpty ? nil : record.targetPath
                        )
                    }
                )

                // 同一份报告写到若干位置；同目录用原名，自定义目录平铺并带来源标识。
                let basePrefix = "DitKit_传输报告_\(config.mode.rawValue)_\(config.algorithm.tag)"
                for output in placement.outputs(natural: target, basePrefix: basePrefix) {
                    try? ensureDir(output.directory)
                    let mhlURL: URL
                    do {
                        mhlURL = try MHLReport.write(
                            entries: entries,
                            process: "transfer",
                            directory: output.directory,
                            filePrefix: output.filePrefix,
                            startedAt: started,
                            finishedAt: reportFinished,
                            detail: detail
                        )
                    } catch {
                        result.reportErrors.append(
                            "\(output.directory.lastPathComponent) 的 MHL 报告写入失败：\(error.localizedDescription)"
                        )
                        continue
                    }
                    result.reportURLs.append(mhlURL)

                    // 配套 PDF（与 MHL 同名、同目录），与 MHL 明细段同源。
                    do {
                        let pdfURL = try writeTransferPDF(
                            records: scoped, mode: config.mode, algorithm: config.algorithm,
                            target: target, mhlURL: mhlURL, startedAt: started,
                            finishedAt: reportFinished, stopped: result.stopped,
                            space: space
                        )
                        result.reportURLs.append(pdfURL)
                    } catch {
                        result.reportErrors.append(
                            "\(output.directory.lastPathComponent) 的 PDF 报告写入失败：\(error.localizedDescription)"
                        )
                    }
                }
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
        stopped: Bool = false,
        space: TransferSpaceEstimate? = nil
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
            case .partial: color = .muted
            case .deleted, .failed: color = .bad
            }
            let verify: String
            if r.action == .deleted || r.action == .partial {
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
                               startedAt: startedAt, finishedAt: finishedAt, stopped: stopped,
                    space: space
                ),
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
        stopped: Bool,
        space: TransferSpaceEstimate? = nil
    ) -> [String] {
        var meta = [
            "模式：\(mode.rawValue)",
            "校验算法：\(algorithm.rawValue)",
            "目标目录：\(target.path)",
            "开始时间：\(PDFReport.readable(startedAt))",
            "结束时间：\(PDFReport.readable(finishedAt))",
        ]
        if let targetSpace = space?.targets.first(where: {
            $0.path == target.standardizedFileURL.path || $0.path == target.path
        }) {
            if targetSpace.requiredBytes > 0 {
                meta.append("预估所需空间：\(PDFReport.byteString(targetSpace.requiredBytes))")
            }
            if targetSpace.freeBytes >= 0 {
                meta.append("目标卷可用空间：\(PDFReport.byteString(targetSpace.freeBytes))")
            }
        }
        if stopped { meta.append("状态：已停止（部分报告，仅含本次已完成的记录）") }
        return meta
    }

    private static func transferSummary(records: [TransferRecord], stopped: Bool) -> [String] {
        let counts = TransferResult(records: records)
        var summary = [
            "复制 \(counts.copied) · 更新 \(counts.updated) · 跳过 \(counts.skipped) · 删除 \(counts.deleted) · 断点 \(counts.partial) · 失败 \(counts.failed) · 校验通过 \(counts.verifiedOK)"
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
        control: RunControl?,
        collected: RecordBox
    ) async throws {
        let entries = expandSources(sources)
        let fm = FileManager.default

        targetLoop: for target in targets {
            guard await shouldContinue(control) else { break targetLoop }
            try ensureDir(target)
            for entry in entries {
                // 文件边界：暂停时等待；大文件内部还会在 4 MiB 块边界保存断点。
                guard await shouldContinue(control) else { break targetLoop }
                let targetURL = target.appendingPathComponent(entry.rel)
                try ensureDir(targetURL.deletingLastPathComponent())

                let exists = fm.fileExists(atPath: targetURL.path)
                let sameSize = exists && FileCopier.fileSize(targetURL) == FileCopier.fileSize(entry.url)
                // 同大小比对时算出的源哈希，若随后要更新可复用，避免大文件二次读盘。
                var comparedSourceHash: String?

                if exists, sameSize {
                    // 大小一致 → 再做内容级哈希校验：一致才跳过，不一致则重新复制更新。
                    let sourceHash = try await FileHasher.hash(fileAt: entry.url, algorithm: algorithm).value
                    comparedSourceHash = sourceHash
                    let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                    if sourceHash == targetHash {
                        collected.records.append(.init(
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

                if exists {
                    try? fm.removeItem(at: targetURL)
                    // 目标被替换，旧断点必须作废，否则下一轮会拿旧部分数据续传到新目标。
                    FileCopier.clearResume(for: targetURL)
                }

                let outcome = try await FileCopier.copyAndHashSourceWithResume(
                    entry.url, to: targetURL, algorithm: algorithm,
                    knownSourceHash: comparedSourceHash, control: control
                )
                guard outcome.completed else {
                    collected.records.append(.init(
                        action: .partial, relativePath: entry.rel,
                        sourcePath: entry.url.path, targetPath: targetURL.path,
                        size: outcome.partialBytes, algorithm: algorithm.tag,
                        sourceHash: "", targetHash: "", verified: false,
                        note: "已停止，保留 \(outcome.partialBytes) 字节断点；下次可继续"
                    ))
                    await onProgress(progress.snapshot(phase: "已保存断点"))
                    return
                }
                let size = outcome.size
                let sourceHash = outcome.sourceHash
                let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                let verified = (sourceHash == targetHash)
                let action: TransferAction = exists ? .updated : .copied
                collected.records.append(.init(
                    action: action, relativePath: entry.rel,
                    sourcePath: entry.url.path, targetPath: targetURL.path,
                    size: size, algorithm: algorithm.tag,
                    sourceHash: sourceHash, targetHash: targetHash,
                    verified: verified,
                    note: verified
                        ? (outcome.resumed ? "从断点续传，校验一致" : "")
                        : "校验失败：源与目标哈希不一致"
                ))
                progress.done(current: entry.rel)
                await onProgress(progress.snapshot(phase: "复制中"))
            }
        }
    }

    // MARK: - 同步模式（目标完全对齐源）

    private static func runSync(
        source: URL,
        targets: [URL],
        algorithm: HashAlgorithm,
        progress: ProgressAccumulator,
        onProgress: @MainActor (TransferProgress) -> Void,
        control: RunControl?,
        collected: RecordBox
    ) async throws {
        let fm = FileManager.default

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
                // 文件边界：暂停时等待；大文件内部还会在 4 MiB 块边界保存断点。
                guard await shouldContinue(control) else { break targetLoop }
                let targetURL = target.appendingPathComponent(item.rel)
                try ensureDir(targetURL.deletingLastPathComponent())
                let exists = fm.fileExists(atPath: targetURL.path)
                let sameSize = exists && FileCopier.fileSize(targetURL) == FileCopier.fileSize(item.url)
                var comparedSourceHash: String?

                if exists, sameSize {
                    // 大小一致 → 再做内容级哈希校验：一致才跳过，不一致则重新同步更新。
                    let sourceHash = try await FileHasher.hash(fileAt: item.url, algorithm: algorithm).value
                    comparedSourceHash = sourceHash
                    let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                    if sourceHash == targetHash {
                        collected.records.append(.init(
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

                if exists {
                    try? fm.removeItem(at: targetURL)
                    FileCopier.clearResume(for: targetURL)
                }
                let outcome = try await FileCopier.copyAndHashSourceWithResume(
                    item.url, to: targetURL, algorithm: algorithm,
                    knownSourceHash: comparedSourceHash, control: control
                )
                guard outcome.completed else {
                    collected.records.append(.init(
                        action: .partial, relativePath: item.rel,
                        sourcePath: item.url.path, targetPath: targetURL.path,
                        size: outcome.partialBytes, algorithm: algorithm.tag,
                        sourceHash: "", targetHash: "", verified: false,
                        note: "已停止，保留 \(outcome.partialBytes) 字节断点；下次可继续"
                    ))
                    await onProgress(progress.snapshot(phase: "已保存断点"))
                    return
                }
                let size = outcome.size
                let sourceHash = outcome.sourceHash
                let targetHash = try await FileHasher.hash(fileAt: targetURL, algorithm: algorithm).value
                let verified = (sourceHash == targetHash)
                let action: TransferAction = exists ? .updated : .copied
                collected.records.append(.init(
                    action: action, relativePath: item.rel,
                    sourcePath: item.url.path, targetPath: targetURL.path,
                    size: size, algorithm: algorithm.tag,
                    sourceHash: sourceHash, targetHash: targetHash,
                    verified: verified,
                    note: verified
                        ? (outcome.resumed ? "从断点续传，校验一致" : "")
                        : "校验失败：源与目标哈希不一致"
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
                        collected.records.append(.init(
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
                            collected.records.append(.init(
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
            // 符号链接一律跳过：既可能指向目录外造成越界，也无法用普通文件哈希正确处理。
            if isSymlink { continue }
            let rel = relativePath(of: child, relativeToBasePath: basePath)
            if isDir {
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
            // 符号链接不参与同步（不补、不删），避免跟随到目录之外。
            if isSymlink { continue }
            let rel = relativePath(of: child, relativeToBasePath: basePath)
            if isDir {
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
    /// 只认新命名：时间在前、形如 `<时间戳>_DitKit_….ext`；旧命名不再保护。
    private static func isReportFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard ext == "mhl" || ext == "pdf" else { return false }
        guard let core = ReportNaming.stripTimestamp(name) else { return false }
        return core.hasPrefix("DitKit_")
    }

    /// 单个目标目录在本次任务中预估需要的额外字节数（纯计算，不接触文件系统写操作）。
    public static func estimateRequiredBytes(config: TransferConfig, target: URL) -> Int64 {
        switch config.mode {
        case .copy:
            return expandSources(config.sources).reduce(Int64(0)) { total, entry in
                total + max(0, FileCopier.fileSize(entry.url))
            }
        case .sync:
            guard let source = config.sources.first else { return 0 }
            let fm = FileManager.default
            return walkFiles(in: source, base: source).reduce(Int64(0)) { total, item in
                let dst = target.appendingPathComponent(item.rel)
                guard fm.fileExists(atPath: dst.path) else {
                    return total + max(0, FileCopier.fileSize(item.url))
                }
                // 同大小且内容一致会跳过；不同大小时引擎先删旧再写新，只需补差值。
                let srcSize = FileCopier.fileSize(item.url)
                let dstSize = FileCopier.fileSize(dst)
                return total + max(0, srcSize - dstSize)
            }
        }
    }

    /// 各目标目录的空间估算：所需字节取本目标口径，可用字节取目标所在卷。
    public static func estimateSpace(config: TransferConfig) -> TransferSpaceEstimate {
        let fm = FileManager.default
        let targets = config.targets.map { target -> TransferSpaceTarget in
            var probe = target
            while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
                probe = probe.deletingLastPathComponent()
            }
            let attrs = try? fm.attributesOfFileSystem(forPath: probe.path)
            let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
            return TransferSpaceTarget(
                path: target.standardizedFileURL.path,
                requiredBytes: estimateRequiredBytes(config: config, target: target),
                freeBytes: free
            )
        }
        return TransferSpaceEstimate(targets: targets)
    }

    static func estimateTotal(config: TransferConfig) -> Int {
        switch config.mode {
        case .copy:
            return max(1, expandSources(config.sources).count * config.targets.count)
        case .sync:
            // 公开入口可能传入空 sources，不能直接强解包；缺失源时按最小总数处理。
            guard let source = config.sources.first else { return 1 }
            return max(1, walkFiles(in: source, base: source).count * config.targets.count)
        }
    }
}

/// 已完成记录的引用容器。用 class 而非 inout 数组，是因为 `async` 函数不能跨 `await` 持有 `inout`；
/// 这样中途抛错时调用方仍能拿到已经完成的记录，避免报告变成空清单。
private final class RecordBox {
    var records: [TransferRecord] = []
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
        // 同步模式的删除项也计入 done，可能超过按源文件估算的 total；UI 进度不能超过 100%。
        let shownDone = min(doneCount, total)
        let shownTotal = max(total, doneCount)
        return TransferProgress(
            filesDone: shownDone, filesTotal: shownTotal,
            currentFile: (current as NSString).lastPathComponent,
            bytesDone: 0, bytesTotal: 0, phase: phase
        )
    }
}
