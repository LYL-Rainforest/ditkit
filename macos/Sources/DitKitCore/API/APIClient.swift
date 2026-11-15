import Foundation

public enum APIClientError: Error, LocalizedError {
    case invalidURL
    case badStatus(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请求地址无效"
        case .badStatus(let code, let body):
            let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(body.utf8)))?.error.message ?? body
            return "后端返回 \(code)：\(detail)"
        case .invalidResponse:
            return "后端响应格式无效"
        }
    }
}

public actor APIClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(runtime: RuntimeInfo) throws {
        guard let url = URL(string: "http://127.0.0.1:\(runtime.port)") else {
            throw APIClientError.invalidURL
        }
        self.baseURL = url
        self.token = runtime.token
        self.session = APIClient.makeSession()
    }

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        self.session = APIClient.makeSession()
    }

    /// 后端只监听 127.0.0.1。系统级 HTTP 代理会拦截本机回环请求并返回 502，
    /// 因此显式清空代理字典，确保 SwiftUI 一定直连守护进程。
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg)
    }

    public func request<T: Decodable & Sendable>(_ path: String, method: String = "GET") async throws -> T {
        let (data, response) = try await session.data(for: makeRequest(path: path, method: method))
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIClientError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeRequest(path: String, method: String = "GET") -> URLRequest {
        // path 可能带查询串，不能用 appendingPathComponent（会把 ? 转义）。
        let url = URL(string: baseURL.absoluteString + path) ?? baseURL
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return req
    }
}
