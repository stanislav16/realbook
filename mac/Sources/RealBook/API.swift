import Foundation

/// Talks to the engine, on this Mac.
@MainActor
final class API {
    let base: URL
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600  // a line in a voice that has to be designed first takes minutes
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    init(base: URL) { self.base = base }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts.url!
    }

    @discardableResult
    func data(_ path: String, method: String = "GET", json: Any? = nil, query: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw AppError(detail ?? "RealBook couldn't do that (\(http.statusCode)).")
        }
        return data
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(path, query: query))
    }

    func object(_ path: String, method: String = "GET", json: Any? = nil) async throws -> [String: Any] {
        let d = try await data(path, method: method, json: json)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}
