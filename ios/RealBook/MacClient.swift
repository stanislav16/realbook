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
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
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

    private func request(_ path: String, method: String = "GET", body: Data? = nil, base: URL) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.httpBody = body
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.setValue(pairing?.key, forHTTPHeaderField: "x-realbook-key")
        return r
    }

    /// Sends a request to whichever of the Mac's addresses answers.
    func data(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let pairing else { throw MacError.notPaired }
        let bases = [working].compactMap { $0 } + pairing.bases.filter { $0 != working }
        for base in bases {
            do {
                let (data, response) = try await session.data(for: request(path, method: method, body: body, base: base))
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
