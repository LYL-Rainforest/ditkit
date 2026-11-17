import Foundation

/// MHL 清单校验：按清单条目重算目录下文件的哈希，逐条给出结论。
public enum MHLVerifier {
    public enum Status: String, Sendable {
        case unchecked    // 尚未校验
        case matched      // 哈希一致
        case mismatch     // 哈希不一致
        case missing      // 文件不存在
        case unsupported  // 清单用了 DitKit 不支持的算法
        case failed       // 读取/计算出错
        case notApplicable // 删除/失败/待处理等记录，本就不该参与哈希校验
    }

    public struct Result: Identifiable, Sendable {
        public let entry: MHLDocument.Entry
        public let status: Status
        public let actualHash: String?
        public let detail: String
        /// 来自 DitKit 完整明细段的操作名；nil 表示普通 MHL 哈希条目。
        public let action: String?
        /// 是否参与一键校验（删除/失败/待处理为 false）。
        public let verifiable: Bool

        public var id: String { entry.id + "\u{1}" + (action ?? "") }

        public init(entry: MHLDocument.Entry, status: Status, actualHash: String? = nil,
                    detail: String = "", action: String? = nil, verifiable: Bool = true) {
            self.entry = entry
            self.status = status
            self.actualHash = actualHash
            self.detail = detail
            self.action = action
            self.verifiable = verifiable
        }
    }

    /// 不参与校验的操作：这些记录在报告里留档，但没有可校验的目标文件。
    private static let nonVerifiableActions: Set<String> = ["删除", "失败", "待处理"]

    /// 未执行校验时的初始行：有完整明细段时按「全部操作记录」展示，否则退回标准哈希条目。
    public static func initialRows(_ document: MHLDocument) -> [Result] {
        guard let detail = document.detail, !detail.records.isEmpty else {
            return document.entries.map { Result(entry: $0, status: .unchecked) }
        }
        return detail.records.map { record in
            let entry = MHLDocument.Entry(
                path: record.path,
                size: record.size,
                lastModificationDate: nil,
                algorithm: record.algorithm,
                hashValue: record.sourceHash,
                previousPath: record.previousPath
            )
            let verifiable = !record.sourceHash.isEmpty
                && !record.algorithm.isEmpty
                && !nonVerifiableActions.contains(record.action)
            let note = record.note.isEmpty
                ? (verifiable ? "" : "本次\(record.action)，不参与哈希校验")
                : record.note
            return Result(entry: entry,
                          status: verifiable ? .unchecked : .notApplicable,
                          detail: note, action: record.action, verifiable: verifiable)
        }
    }

    /// 批量校验结果：停止时 rows 中未处理条目保持 `.unchecked`。
    public struct VerifyOutcome: Sendable {
        public let rows: [Result]
        public let stopped: Bool
    }

    /// 逐条重算哈希（顺序执行，避免同时把多个大文件读进内存），无控制版本。
    public static func verify(_ document: MHLDocument) async -> [Result] {
        await verifyControlled(document, control: nil, onProgress: nil).rows
    }

    /// 可暂停 / 停止的批量校验：校验清单里的全部行。
    public static func verifyControlled(
        _ document: MHLDocument,
        control: RunControl?,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> VerifyOutcome {
        await verifySelected(initialRows(document), in: document,
                             control: control, onProgress: onProgress)
    }

    /// 只校验传入的行（查看器按操作筛选后的「校验当前」）。
    /// 返回与入参同序、等长的结果，调用方按索引合并回全量列表即可。
    public static func verifySelected(
        _ selected: [Result],
        in document: MHLDocument,
        control: RunControl?,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> VerifyOutcome {
        var rows = selected
        let total = rows.count
        for (index, row) in rows.enumerated() {
            if let control, !(await control.gate()) {
                return VerifyOutcome(rows: rows, stopped: true)
            }
            await Task.yield()
            await onProgress?(index + 1, total)
            // 删除/失败等记录只展示、不重算哈希（文件本就不存在）。
            guard row.verifiable else { continue }
            let checked = await verifyOne(row.entry, in: document)
            rows[index] = Result(entry: row.entry, status: checked.status,
                                 actualHash: checked.actualHash, detail: checked.detail,
                                 action: row.action, verifiable: row.verifiable)
        }
        return VerifyOutcome(rows: rows, stopped: false)
    }

    private static func verifyOne(_ entry: MHLDocument.Entry, in document: MHLDocument) async -> Result {
        let fm = FileManager.default
        guard let algorithm = HashAlgorithm(mhlTag: entry.algorithm) else {
            return .init(entry: entry, status: .unsupported,
                         detail: "DitKit 暂不支持 \(entry.algorithm) 算法")
        }
        // 清单来自外部文件，path 必须是指向清单目录内的相对路径，杜绝 ../ 穿越读取任意文件。
        guard let fileURL = safeURL(for: entry.path, under: document.directory) else {
            return .init(entry: entry, status: .failed,
                         detail: "清单条目路径非法：只允许清单目录内的相对路径")
        }
        guard fm.fileExists(atPath: fileURL.path) else {
            return .init(entry: entry, status: .missing, detail: "文件不存在")
        }
        do {
            let (actual, size) = try await FileHasher.hash(fileAt: fileURL, algorithm: algorithm)
            if actual.lowercased() == entry.hashValue.lowercased() {
                return .init(entry: entry, status: .matched, actualHash: actual,
                             detail: sizeMismatch(entry.size, size) ? "哈希一致，但大小与清单不符" : "")
            } else {
                return .init(entry: entry, status: .mismatch, actualHash: actual,
                             detail: "实际哈希与清单不一致")
            }
        } catch {
            return .init(entry: entry, status: .failed, detail: error.localizedDescription)
        }
    }

    private static func sizeMismatch(_ expected: Int64?, _ actual: Int64) -> Bool {
        guard let expected else { return false }
        return expected != actual
    }

    /// 把清单里的相对路径解析成目录内的安全 URL；绝对路径、`..` 越界、符号链接跳出都拒绝。
    /// 返回 nil 表示该条目路径非法，不应读取。
    static func safeURL(for relativePath: String, under directory: URL) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        // 绝对路径（含 Windows 盘符形式）一律拒绝。
        if relativePath.hasPrefix("/") || relativePath.contains(":\\") { return nil }
        let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
        let base = directory.standardizedFileURL
        let baseResolved = base.resolvingSymlinksInPath().path
        let candidateResolved = candidate.resolvingSymlinksInPath().path
        func isUnder(_ path: String, root: String) -> Bool {
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        // 标准化路径与符号链接解析后都必须仍位于目录内，双保险。
        guard isUnder(candidate.path, root: base.path),
              isUnder(candidateResolved, root: baseResolved) else { return nil }
        return candidate
    }
}
