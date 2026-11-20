import Foundation

/// 完整报告明细：与 PDF 同源的信息，写入 `.mhl` 的 `dk:report` 扩展段。
///
/// `hashes` 只能收录存在且有哈希的文件，因此跳过/删除/失败等操作由这里完整留档；
/// 查看器优先按 `records` 展示全部行，删除/失败行不参与哈希校验。
public struct MHLReportDetail: Sendable {
    public struct Record: Identifiable, Sendable {
        /// 操作名：复制 / 更新 / 跳过 / 删除 / 失败 / 已重命名 / 无需改动 / 待处理。
        public let action: String
        /// 相对清单所在目录的路径（重命名场景为新文件名）。
        public let path: String
        /// 改动前的路径 / 原文件名。
        public let previousPath: String?
        public let size: Int64?
        /// MHL 元素名，例如 "xxh128" / "md5"。
        public let algorithm: String
        public let sourceHash: String
        public let targetHash: String
        /// 校验结果：一致 / 不一致 / —。
        public let verify: String
        public let note: String
        public let sourcePath: String?
        public let targetPath: String?

        public var id: String { action + "\u{1}" + path + "\u{1}" + sourceHash }

        public init(
            action: String,
            path: String,
            previousPath: String? = nil,
            size: Int64? = nil,
            algorithm: String = "",
            sourceHash: String = "",
            targetHash: String = "",
            verify: String = "",
            note: String = "",
            sourcePath: String? = nil,
            targetPath: String? = nil
        ) {
            self.action = action
            self.path = path
            self.previousPath = previousPath
            self.size = size
            self.algorithm = algorithm
            self.sourceHash = sourceHash
            self.targetHash = targetHash
            self.verify = verify
            self.note = note
            self.sourcePath = sourcePath
            self.targetPath = targetPath
        }
    }

    /// 与 PDF 一致的元信息行（模式、目录、时间、状态等）。
    public let meta: [String]
    /// 与 PDF 一致的汇总行。
    public let summary: [String]
    /// 本次任务的全部操作记录（顺序与 PDF 明细表一致）。
    public let records: [Record]

    public init(meta: [String] = [], summary: [String] = [], records: [Record] = []) {
        self.meta = meta
        self.summary = summary
        self.records = records
    }
}

/// ASC MHL v2.0（媒体哈希清单）生成器，遵循官方 xsd/ASCMHL.xsd：
///
/// ```xml
/// <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
///   <creatorinfo>
///     <creationdate>ISO8601</creationdate>
///     <hostname>…</hostname>
///     <tool version="0.3.1">DitKit</tool>
///   </creatorinfo>
///   <processinfo>
///     <process>transfer|in-place|flatten</process>
///   </processinfo>
///   <hashes>
///     <hash>
///       <path size="…" lastmodificationdate="ISO8601">相对路径</path>
///       <xxh128>64 位十六进制（大端）</xxh128>
///       <previousPath>原路径（可选，重命名场景）</previousPath>
///     </hash>
///   </hashes>
/// </hashlist>
/// ```
///
/// 哈希值要求（规范 Appendix D）：XXH128 大端、seed 0，与 `xxhsum -H2` 输出一致；
/// MD5 为常规 32 位十六进制——与 DitKit 现有哈希输出格式完全兼容。
///
/// `<hashes>` 严格保持官方规范（每条对应一个存在、可校验哈希的文件）；
/// 报告的全部信息（含跳过/删除/失败等没有有效目标文件的操作）放在独立命名空间
/// 的 `dk:report` 明细段里，第三方工具按 `<hashes>` 解析不受影响，DitKit 查看器可读完整记录。
public enum MHLReport {
    public struct Entry: Sendable {
        /// 相对于清单所在目录的路径。
        public let path: String
        public let size: Int64?
        public let lastModificationDate: Date?
        /// xsd 元素名："md5" / "xxh128" / "xxh3" / "xxh64" / "sha1" / "c4"。
        public let algorithm: String
        public let hashValue: String
        /// 重命名场景：改动前的原路径。
        public let previousPath: String?

        public init(
            path: String,
            size: Int64? = nil,
            lastModificationDate: Date? = nil,
            algorithm: String,
            hashValue: String,
            previousPath: String? = nil
        ) {
            self.path = path
            self.size = size
            self.lastModificationDate = lastModificationDate
            self.algorithm = algorithm
            self.hashValue = hashValue
            self.previousPath = previousPath
        }
    }

    /// 在 `directory` 根写一份 `.mhl` 清单，返回文件 URL。
    public static func write(
        entries: [Entry],
        process: String,
        directory: URL,
        filePrefix: String,
        startedAt: Date,
        finishedAt: Date,
        toolVersion: String = "0.3.1",
        detail: MHLReportDetail? = nil
    ) throws -> URL {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(iso(startedAt))</creationdate>
            <hostname>\(escape(hostname()))</hostname>
            <tool version="\(escape(toolVersion))">DitKit</tool>
          </creatorinfo>
          <processinfo>
            <process>\(process)</process>
          </processinfo>
          <hashes>
        """
        for entry in entries {
            var attrs = ""
            if let size = entry.size { attrs += " size=\"\(size)\"" }
            if let mtime = entry.lastModificationDate { attrs += " lastmodificationdate=\"\(iso(mtime))\"" }
            xml += "\n    <hash>"
            xml += "\n      <path\(attrs)>\(escape(entry.path))</path>"
            xml += "\n      <\(entry.algorithm)>\(escape(entry.hashValue))</\(entry.algorithm)>"
            if let previous = entry.previousPath {
                xml += "\n      <previousPath>\(escape(previous))</previousPath>"
            }
            xml += "\n    </hash>"
        }
        xml += "\n  </hashes>"
        if let detail { xml += detailXML(detail) }
        xml += "\n</hashlist>\n"

        let fileURL = directory.appendingPathComponent(
            ReportNaming.fileName(filePrefix: filePrefix, ext: "mhl", at: finishedAt)
        )
        // 先原子落盘新报告，成功后再清理旧报告；避免写失败时连历史清单一起丢失。
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        cleanPreviousReports(directory: directory, filePrefix: filePrefix, except: fileURL)
        return fileURL
    }

    /// 独立命名空间的完整明细段：不污染标准 `<hashes>`，官方工具仍能按规范读取哈希条目。
    private static func detailXML(_ detail: MHLReportDetail) -> String {
        var xml = "\n  <dk:report xmlns:dk=\"urn:ditkit:report:v1\">"
        xml += "\n    <dk:meta>"
        for line in detail.meta { xml += "\n      <dk:line>\(escape(line))</dk:line>" }
        xml += "\n    </dk:meta>"
        xml += "\n    <dk:summary>"
        for line in detail.summary { xml += "\n      <dk:line>\(escape(line))</dk:line>" }
        xml += "\n    </dk:summary>"
        xml += "\n    <dk:records>"
        for record in detail.records {
            xml += "\n      <dk:record action=\"\(escape(record.action))\">"
            xml += "\n        <dk:path>\(escape(record.path))</dk:path>"
            if let previous = record.previousPath {
                xml += "\n        <dk:previousPath>\(escape(previous))</dk:previousPath>"
            }
            if let size = record.size {
                xml += "\n        <dk:size>\(size)</dk:size>"
            }
            if !record.algorithm.isEmpty {
                xml += "\n        <dk:algorithm>\(escape(record.algorithm))</dk:algorithm>"
            }
            if !record.sourceHash.isEmpty {
                xml += "\n        <dk:sourceHash>\(escape(record.sourceHash))</dk:sourceHash>"
            }
            if !record.targetHash.isEmpty {
                xml += "\n        <dk:targetHash>\(escape(record.targetHash))</dk:targetHash>"
            }
            if !record.verify.isEmpty {
                xml += "\n        <dk:verify>\(escape(record.verify))</dk:verify>"
            }
            if let source = record.sourcePath, !source.isEmpty {
                xml += "\n        <dk:sourcePath>\(escape(source))</dk:sourcePath>"
            }
            if let target = record.targetPath, !target.isEmpty {
                xml += "\n        <dk:targetPath>\(escape(target))</dk:targetPath>"
            }
            if !record.note.isEmpty {
                xml += "\n        <dk:note>\(escape(record.note))</dk:note>"
            }
            xml += "\n      </dk:record>"
        }
        return xml + "\n    </dk:records>\n  </dk:report>"
    }

    private static func hostname() -> String {
        let host = Host.current()
        return host.localizedName ?? host.name ?? ""
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// 删除目录根中同一前缀的历史报告（.mhl/.pdf），保证每个目标只保留最新一组。
    /// 只认新命名（时间在前，`时间戳_前缀.ext`）；旧命名不再识别，留在目录里也不会被删。
    /// - parameter except: 刚写入的新报告，清理时必须跳过，否则会把自己删掉。
    public static func cleanPreviousReports(directory: URL, filePrefix: String, except: URL? = nil) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let keep = except?.standardizedFileURL.path
        for child in children {
            if let keep, child.standardizedFileURL.path == keep { continue }
            let name = child.lastPathComponent
            let ext = child.pathExtension.lowercased()
            guard ext == "mhl" || ext == "pdf" else { continue }
            // 只匹配新格式：<时间戳>_<prefix>.ext。
            let matches = ReportNaming.stripTimestamp(name).map { $0 == filePrefix + "." + ext } ?? false
            if matches { try? fm.removeItem(at: child) }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
