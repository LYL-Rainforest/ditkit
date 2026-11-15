import Foundation

/// 重命名场景的报告生成（每个发生重命名的目录根各写一组）：
/// - **MHL**：ASC MHL v2.0 清单（process="in-place"），覆盖「已重命名 + 无需改动」且文件实际存在者，
///   逐个计算 xxh128（规范要求哈希条目必须带哈希值）；「已重命名」条目用 `previousPath` 记录原文件名；
/// - **PDF**：人类可读的完整明细表（含失败项），文件名与 MHL 同名、扩展名 `.pdf`；
/// - 失败文件不写入 MHL 清单（其状态在 PDF 与界面中展示）。
public enum RenameMHL {
    /// - parameter onlyCompleted: 停止场景下只把已完成项写入报告，剩余 `.pending` 项不列入清单；
    /// - parameter statusNote: 附加到 PDF 的状态说明（例如「已停止（部分报告）」）；
    /// - parameter allowEmpty: 即使一个文件都没处理完，也生成一组空的 MHL + PDF。
    public static func write(
        items: [RenameItem],
        startedAt: Date,
        finishedAt: Date,
        onlyCompleted: Bool = false,
        statusNote: String? = nil,
        allowEmpty: Bool = false
    ) async throws -> [URL] {
        let fm = FileManager.default
        var byDirectory: [String: [RenameItem]] = [:]
        for item in items {
            byDirectory[item.directory.standardizedFileURL.path, default: []].append(item)
        }

        var urls: [URL] = []
        for dirPath in byDirectory.keys.sorted() {
            let group = byDirectory[dirPath]!.sorted { $0.originalName < $1.originalName }
            let renamed = group.filter { item in
                if case .renamed = item.state { return true }
                return false
            }
            let completedCount = group.filter { $0.state != .pending }.count
            guard (!renamed.isEmpty || (allowEmpty && completedCount > 0)),
                  let dirURL = group.first?.directory else { continue }

            var entries: [MHLReport.Entry] = []
            var pdfRows: [PDFReport.Row] = []
            var detailRecords: [MHLReportDetail.Record] = []
            for item in group {
                if onlyCompleted && item.state == .pending { continue }
                let fileURL = item.directory.appendingPathComponent(item.proposedName)
                let exists = fm.fileExists(atPath: fileURL.path)

                let actionLabel: String
                let rowColor: PDFReport.RowColor
                switch item.state {
                case .renamed:
                    actionLabel = "已重命名"
                    rowColor = .good
                case .unchanged:
                    actionLabel = "无需改动"
                    rowColor = .muted
                case .skipped:
                    actionLabel = "跳过"
                    rowColor = .muted
                case .failed:
                    actionLabel = "失败"
                    rowColor = .bad
                case .pending:
                    actionLabel = "待处理"
                    rowColor = .muted
                }

                var hash = "—"
                if exists {
                    let (value, _) = try await FileHasher.hash(fileAt: fileURL, algorithm: .xxHash128)
                    hash = value
                    // 失败文件不进入 MHL 清单。
                    if case .failed = item.state { } else {
                        let mtime = try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
                        let previous: String?
                        if case .renamed = item.state {
                            previous = item.originalName
                        } else {
                            previous = nil
                        }
                        entries.append(MHLReport.Entry(
                            path: item.proposedName,
                            size: FileCopier.fileSize(fileURL),
                            lastModificationDate: mtime,
                            algorithm: "xxh128",
                            hashValue: hash,
                            previousPath: previous
                        ))
                    }
                }
                pdfRows.append(PDFReport.Row(
                    [actionLabel, item.originalName, item.proposedName, hash],
                    color: rowColor
                ))

                // 完整明细段：失败/跳过等也要留档（PDF 有，MHL 也要有）。
                var previous: String?
                if case .renamed = item.state { previous = item.originalName }
                var note = ""
                if case .skipped(let why) = item.state { note = why }
                if case .failed(let why) = item.state { note = why }
                detailRecords.append(MHLReportDetail.Record(
                    action: actionLabel,
                    path: item.proposedName,
                    previousPath: previous,
                    size: exists ? FileCopier.fileSize(fileURL) : nil,
                    algorithm: exists ? "xxh128" : "",
                    sourceHash: hash == "—" ? "" : hash,
                    verify: exists ? "一致" : "—",
                    note: note,
                    sourcePath: item.url.path,
                    targetPath: fileURL.path
                ))
            }
            if pdfRows.isEmpty {
                pdfRows.append(.init(["已停止", "—", "本次没有已完成的文件", "—"], color: .muted))
                detailRecords.append(.init(action: "已停止", path: "—", note: "本次没有已完成的文件"))
            }

            // 元信息与汇总：MHL 明细段与 PDF 共用，保证两份报告信息一致。
            let unchanged = group.filter { $0.state == .unchanged }.count
            let failed = group.filter {
                if case .failed = $0.state { return true }
                return false
            }.count
            var meta = [
                "目录：\(dirURL.path)",
                "开始时间：\(PDFReport.readable(startedAt))",
                "结束时间：\(PDFReport.readable(finishedAt))",
            ]
            var summary = ["已重命名 \(renamed.count) · 无需改动 \(unchanged) · 失败 \(failed)"]
            if let statusNote {
                meta.append("状态：\(statusNote)")
                let pending = group.filter { $0.state == .pending }.count
                summary.append("未处理 \(pending) 项（保留原文件名）")
            }
            let detail = MHLReportDetail(meta: meta, summary: summary, records: detailRecords)

            // MHL 清单（无有效条目时跳过；停止场景仍写空清单，便于留档）。
            var mhlURL: URL?
            if !entries.isEmpty || allowEmpty {
                mhlURL = try MHLReport.write(
                    entries: entries,
                    process: "in-place",
                    directory: dirURL,
                    filePrefix: "DitKit_重命名报告",
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    detail: detail
                )
                if let url = mhlURL { urls.append(url) }
            }

            // PDF 明细表：文件名与 MHL 同名（或独立时间戳名）。
            let pdfURL = (mhlURL ?? dirURL.appendingPathComponent("DitKit_重命名报告_\(pdfTimestamp(finishedAt))"))
                .deletingPathExtension().appendingPathExtension("pdf")
            try PDFReport.write(
                title: "DitKit 重命名报告",
                meta: meta,
                summary: summary,
                columns: [
                    .init(name: "操作", width: 62),
                    .init(name: "原文件名", width: 0),
                    .init(name: "新文件名", width: 0),
                    .init(name: "xxh128", width: 138, monospace: true),
                ],
                rows: pdfRows,
                to: pdfURL
            )
            urls.append(pdfURL)
        }
        return urls
    }

    private static func pdfTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmssSSS"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
