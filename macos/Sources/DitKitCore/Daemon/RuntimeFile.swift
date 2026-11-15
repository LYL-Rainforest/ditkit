import Foundation

public struct RuntimeInfo: Codable, Sendable {
    public let port: Int
    public let token: String
    public let pid: Int
    public let version: String
    public let dataDir: String
    public let startedAt: String

    private enum CodingKeys: String, CodingKey {
        case port, token, pid, version
        case dataDir = "data_dir"
        case startedAt = "started_at"
    }
}

public enum RuntimeStore {
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DitKit/runtime.json")
    }

    public static func load(at url: URL = defaultURL()) throws -> RuntimeInfo {
        let data = try Data(contentsOf: url)
        let info = try JSONDecoder().decode(RuntimeInfo.self, from: data)
        guard info.port > 0, !info.token.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return info
    }
}
