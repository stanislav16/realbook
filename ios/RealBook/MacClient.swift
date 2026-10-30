import Foundation

/// The Mac this iPhone is paired with, from the code in RealBook's "Listen on iPhone" tab:
/// http://192.168.1.20:47321/?key=…&mac=Stanislavs-MacBook-Pro.local
struct Pairing: Codable, Equatable {
    var address: String   // "192.168.1.20:47321"
    var macName: String?  // "Stanislavs-MacBook-Pro.local", for when the address changes
    var key: String

    init?(link: String) {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let key = parts.queryItems?.first(where: { $0.name == "key" })?.value, !key.isEmpty
        else { return nil }
        address = "\(host):\(url.port ?? 47321)"
        macName = parts.queryItems?.first(where: { $0.name == "mac" })?.value
        self.key = key
    }

    /// The addresses to try, the last one that worked first.
    var bases: [URL] {
        var hosts = [address]
        if let name = macName, let port = address.split(separator: ":").last { hosts.append("\(name):\(port)") }
        return hosts.compactMap { URL(string: "http://\($0)") }
    }
}

enum MacError: LocalizedError {
    case notPaired, unreachable, refused(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: "Pair this iPhone with RealBook on your Mac first."
        case .unreachable: "Can't reach your Mac. It needs to be on, with RealBook open, on the same Wi‑Fi."
        case .refused(let why): why
        }
    }
}

/// Talks to RealBook on the Mac over the home network.
@MainActor
final class MacClient {
    static let shared = MacClient()

    private(set) var pairing: Pairing? = {
        guard let data = UserDefaults.standard.data(forKey: "pairing") else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }()
    private var working: URL?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // each request sets its own, shorter, timeout
        config.waitsForConnectivity = false
        config.urlCache = nil  // a line's audio changes when its speaker does
        return URLSession(configuration: config)
    }()

    func pair(_ p: Pairing) {
        pairing = p
        working = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: "pairing")
    }

    func unpair() {
        pairing = nil
        working = nil
        UserDefaults.standard.removeObject(forKey: "pairing")
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [],
                         timeout: TimeInterval = 6, base: URL) -> URLRequest {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var r = URLRequest(url: parts.url!, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.setValue(pairing?.key, forHTTPHeaderField: "x-realbook-key")
        return r
    }

    /// Sends a request to whichever of the Mac's addresses answers.
    func data(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [],
              timeout: TimeInterval = 6) async throws -> Data {
        guard let pairing else { throw MacError.notPaired }
        let bases = [working].compactMap { $0 } + pairing.bases.filter { $0 != working }
        for base in bases {
            do {
                let r = request(path, method: method, body: body, query: query, timeout: timeout, base: base)
                let (data, response) = try await session.data(for: r)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                working = base
                if status == 403 { throw MacError.refused("Your Mac didn't accept this iPhone. Pair it again with the code in RealBook's Listen on iPhone tab.") }
                guard (200..<300).contains(status) else {
                    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                    throw MacError.refused(detail ?? "Your Mac answered with an error (\(status)).")
                }
                return data
            } catch let error as MacError {
                throw error
            } catch {
                continue  // try the next address
            }
        }
        working = nil
        throw MacError.unreachable
    }

    func books() async throws -> [RemoteBook] {
        try JSONDecoder().decode([RemoteBook].self, from: await data("api/phone/books"))
    }

    func book(_ id: String) async throws -> MacBook {
        try JSONDecoder().decode(MacBook.self, from: await data("api/books/\(id)"))
    }

    func chapter(_ n: Int, of id: String) async throws -> MacChapter {
        try JSONDecoder().decode(MacChapter.self, from: await data("api/books/\(id)/chapters/\(n)", timeout: 20))
    }

    /// One line's audio, made on the Mac if it hasn't been yet (which can take a few seconds).
    func line(_ segment: Int, chapter: Int, of id: String, ahead: Bool = false) async throws -> Data {
        try await data("api/books/\(id)/audio/\(chapter)/\(segment)", query: ahead ? [URLQueryItem(name: "prefetch", value: "1")] : [],
                       timeout: 120)
    }

    /// Gives a quote to another character (nil: the narrator reads it). Returns the lines that changed
    /// and the cast with its new line counts.
    func setSpeaker(_ speaker: String?, chapter: Int, segment: Int, of id: String) async throws -> (changed: [Int], cast: [MacBook.Member]) {
        struct Body: Encodable { var speaker: String? }
        struct Reply: Decodable { var changed: [Int]; var cast: [MacBook.Member] }
        let body = try JSONEncoder().encode(Body(speaker: speaker))
        let data = try await data("api/books/\(id)/chapters/\(chapter)/segments/\(segment)/speaker", method: "PUT", body: body)
        let r = try JSONDecoder().decode(Reply.self, from: data)
        return (r.changed, r.cast)
    }

    /// The Mac's reading page look (the Aa menu), to start from.
    func appearance() async throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: await data("api/config", timeout: 20)) as? [String: Any]
        return json?["appearance"] as? [String: Any] ?? [:]
    }

    /// A character's voice saying a line, made on the Mac.
    func sample(_ v: VoiceSample, text: String) async throws -> Data {
        try await data("api/preview", query: [URLQueryItem(name: "voice", value: v.voice), URLQueryItem(name: "rate", value: String(v.rate)),
                                              URLQueryItem(name: "pitch_shift", value: String(v.pitchShift)),
                                              URLQueryItem(name: "text", value: text)],
                       timeout: 120)
    }

    func cover(_ id: String) async throws -> Data {
        try await data("api/books/\(id)/cover", timeout: 20)
    }

    func startExport(_ id: String) async throws {
        _ = try await data("api/books/\(id)/export", method: "POST")
    }

    /// Tells the Mac where the reader got to; returns the Mac's position if it has a newer one.
    func send(position: MacPosition, book id: String) async throws -> MacPosition? {
        let reply = try await data("api/books/\(id)/position", method: "PUT", body: try JSONEncoder().encode(position))
        struct Reply: Codable { var ok: Bool; var position: MacPosition? }
        let r = try JSONDecoder().decode(Reply.self, from: reply)
        return r.ok ? nil : r.position
    }

    /// Downloads a file from the Mac to `target`, reporting progress from 0 to 1.
    func download(_ path: String, to target: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let pairing else { throw MacError.notPaired }
        let bases = [working].compactMap { $0 } + pairing.bases.filter { $0 != working }
        var lastError: Error = MacError.unreachable
        for base in bases {
            let reporter = ProgressReporter(progress)
            do {
                let (file, response) = try await URLSession.shared.download(for: request(path, base: base), delegate: reporter)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw MacError.refused("Your Mac couldn't send the file (\(status)).") }
                working = base
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: file, to: target)
                return
            } catch let error as MacError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError is URLError ? MacError.unreachable : lastError
    }
}

private final class ProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @MainActor (Double) -> Void

    init(_ report: @escaping @MainActor (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let fraction = Double(written) / Double(expected)
        Task { @MainActor in report(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
