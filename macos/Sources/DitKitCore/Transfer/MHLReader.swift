import Foundation

/// ASC MHL v2.0 清单读取器：把 `.mhl` XML 解析成可展示的模型。
///
/// 用 `XMLNode.localName` 而不是 `name`，这样带默认命名空间 `urn:ASC:MHL:v2.0`
/// 的官方清单和 DitKit 自己生成的清单都能读。
public struct MHLDocument: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let path: String
        public let size: Int64?
        public let lastModificationDate: String?
        /// MHL 元素名："xxh128" / "md5" / "xxh3" / "xxh64" / "sha1" / "c4" 等。
        public let algorithm: String
        public let hashValue: String
        public let previousPath: String?

        public var id: String { path + "\u{1}" + hashValue }

        public init(path: String, size: Int64?, lastModificationDate: String?,
                    algorithm: String, hashValue: String, previousPath: String?) {
            self.path = path
            self.size = size
            self.lastModificationDate = lastModificationDate
            self.algorithm = algorithm
            self.hashValue = hashValue
            self.previousPath = previousPath
        }
    }

    public let url: URL
    /// 清单所在目录：校验时以它为根拼接条目里的相对路径。
    public let directory: URL
    public let version: String
    public let creationDate: String
    public let hostname: String
    public let toolName: String
    public let toolVersion: String
    public let process: String
    public let entries: [Entry]
    /// DitKit 完整明细段（自定义命名空间）；第三方清单或旧清单为 nil。
    public let detail: MHLReportDetail?
}

public enum MHLReaderError: LocalizedError, Sendable {
    case notHashlist
    case missingHashes

    public var errorDescription: String? {
        switch self {
        case .notHashlist: return "不是有效的 ASC MHL 清单（根节点应为 hashlist）"
        case .missingHashes: return "清单中缺少 hashes 区块"
        }
    }
}

public enum MHLReader {
    /// 规范中的哈希元素名（小写）；未知算法仍会读出，但校验时会标记为「不支持」。
    private static let algorithmNames: Set<String> = [
        "md5", "xxh128", "xxh3", "xxh64", "sha1", "sha256", "c4",
    ]

    public static func read(_ url: URL) throws -> MHLDocument {
        let data = try Data(contentsOf: url)
        let xml = try XMLDocument(data: data, options: [])
        guard let root = xml.rootElement(), localName(root) == "hashlist" else {
            throw MHLReaderError.notHashlist
        }

        let creator = first(root, "creatorinfo")
        let tool = creator.flatMap { first($0, "tool") }
        let processInfo = first(root, "processinfo")
        let hashes = first(root, "hashes")

        var entries: [MHLDocument.Entry] = []
        if let hashes {
            for hash in elements(hashes).filter({ localName($0) == "hash" }) {
                let pathNode = first(hash, "path")
                let path = text(pathNode)
                guard !path.isEmpty else { continue }

                var algorithm = ""
                var value = ""
                for child in elements(hash) {
                    let name = localName(child).lowercased()
                    if algorithmNames.contains(name) {
                        algorithm = name
                        value = text(child)
                        break
                    }
                }

                let sizeString = (pathNode as? XMLElement)?.attribute(forName: "size")?.stringValue
                let mtime = (pathNode as? XMLElement)?.attribute(forName: "lastmodificationdate")?.stringValue
                let previous = first(hash, "previousPath").map(text)

                entries.append(.init(
                    path: path,
                    size: sizeString.flatMap { Int64($0) },
                    lastModificationDate: mtime,
                    algorithm: algorithm,
                    hashValue: value,
                    previousPath: previous?.isEmpty == true ? nil : previous
                ))
            }
        }

        let toolVersion = (tool as? XMLElement)?.attribute(forName: "version")?.stringValue ?? ""
        let detail = first(root, "report").map(parseDetail)
        return MHLDocument(
            url: url,
            directory: url.deletingLastPathComponent(),
            version: root.attribute(forName: "version")?.stringValue ?? "",
            creationDate: text(creator.flatMap { first($0, "creationdate") }),
            hostname: text(creator.flatMap { first($0, "hostname") }),
            toolName: text(tool),
            toolVersion: toolVersion,
            process: text(processInfo.flatMap { first($0, "process") }),
            entries: entries,
            detail: detail
        )
    }

    // MARK: - DitKit 完整明细段

    private static func parseDetail(_ node: XMLNode) -> MHLReportDetail {
        var records: [MHLReportDetail.Record] = []
        if let recordsNode = first(node, "records") {
            for recordNode in elements(recordsNode).filter({ localName($0) == "record" }) {
                let path = text(first(recordNode, "path"))
                guard !path.isEmpty else { continue }
                let previous = text(first(recordNode, "previousPath"))
                let source = text(first(recordNode, "sourcePath"))
                let target = text(first(recordNode, "targetPath"))
                records.append(.init(
                    action: (recordNode as? XMLElement)?.attribute(forName: "action")?.stringValue ?? "",
                    path: path,
                    previousPath: previous.isEmpty ? nil : previous,
                    size: Int64(text(first(recordNode, "size"))),
                    algorithm: text(first(recordNode, "algorithm")),
                    sourceHash: text(first(recordNode, "sourceHash")),
                    targetHash: text(first(recordNode, "targetHash")),
                    verify: text(first(recordNode, "verify")),
                    note: text(first(recordNode, "note")),
                    sourcePath: source.isEmpty ? nil : source,
                    targetPath: target.isEmpty ? nil : target
                ))
            }
        }
        return MHLReportDetail(
            meta: lines(first(node, "meta")),
            summary: lines(first(node, "summary")),
            records: records
        )
    }

    private static func lines(_ node: XMLNode?) -> [String] {
        guard let node else { return [] }
        return elements(node).filter { localName($0) == "line" }.map { text($0) }
    }

    // MARK: - XML 辅助（忽略命名空间）

    private static func localName(_ node: XMLNode) -> String {
        // 带前缀的节点（dk:record）与默认命名空间节点都只取本地名。
        let raw = (node.localName ?? node.name ?? "").lowercased()
        return raw.split(separator: ":").last.map(String.init) ?? raw
    }

    private static func elements(_ node: XMLNode) -> [XMLNode] {
        (node.children ?? []).filter { $0.kind == .element }
    }

    private static func first(_ node: XMLNode, _ name: String) -> XMLNode? {
        let wanted = name.lowercased()
        return elements(node).first { localName($0) == wanted }
    }

    private static func text(_ node: XMLNode?) -> String {
        (node?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
