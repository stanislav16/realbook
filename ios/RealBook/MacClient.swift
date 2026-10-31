import CryptoKit
import Foundation
import Network

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
    case notPaired, unreachable, notSaved, refused(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: "Pair this iPhone with RealBook on your Mac first."
        case .unreachable: "Can't reach your Mac. It needs to be on, with RealBook open, on the same Wi‑Fi."
        case .notSaved: "This part isn't on this iPhone yet. The next hours are saved by themselves whenever your Mac is near."
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
    let finder = MacFinder()
    /// The network changed or the Mac was announced: a good moment to look for it.
    var changed: (() -> Void)?
    private var working: URL?
    private var lastWorked = Date.distantPast
    private var locating: Task<URL, Error>?
    private let monitor = NWPathMonitor()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // each request sets its own, shorter, timeout
        config.waitsForConnectivity = false
        config.urlCache = nil  // a line's audio changes when its speaker does
        return URLSession(configuration: config)
    }()

    private init() {
        finder.changed = { [weak self] in self?.changed?() }
        finder.start()
        monitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.working = nil
                self?.changed?()
            }
        }
        monitor.start(queue: .main)
    }

    func pair(_ p: Pairing) {
        pairing = p
        working = nil
        savePairing()
    }

    func unpair() {
        pairing = nil
        working = nil
        UserDefaults.standard.removeObject(forKey: "pairing")
    }

    private func savePairing() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pairing), forKey: "pairing")
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

    // MARK: - finding the Mac

    private enum Answer { case mine(name: String?), notMine, tooOld, nothing }

    /// Asks an address whether it's this iPhone's Mac: it answers with proof that it has the pairing
    /// key, and the key itself is only ever sent to an address that did.
    private func hello(_ base: URL, key: String) async -> Answer {
        struct Reply: Decodable { var proof: String; var mac: String? }
        let nonce = UUID().uuidString
        var parts = URLComponents(url: base.appendingPathComponent("api/hello"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        guard let (data, response) = try? await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 3)),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .nothing }
        if status == 404 { return .tooOld }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return .nothing }
        let code = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(key.utf8)))
        let proof = code.map { String(format: "%02x", $0) }.joined()
        return reply.proof == proof ? .mine(name: reply.mac) : .notMine
    }

    /// The address to use: the last one that worked if it did just now, else whichever answers.
    private func base() async throws -> URL {
        if let working, Date().timeIntervalSince(lastWorked) < 30 { return working }
        if let locating { return try await locating.value }
        let task = Task { try await self.locate() }
        locating = task
        defer { locating = nil }
        return try await task.value
    }

    private func locate() async throws -> URL {
        guard let pairing else { throw MacError.notPaired }
        let own = pairing.bases
        var tried = Set<URL>()
        var refusal: MacError?
        for round in 0..<2 {
            let found = finder.addresses.compactMap { URL(string: "http://\($0)") }
            let tries = ([working].compactMap { $0 } + own + found).filter { tried.insert($0).inserted }
            if round == 1 && tries.isEmpty { break }
            let winner = await withTaskGroup(of: (URL, Answer).self) { group -> (URL, String?)? in
                for url in tries { group.addTask { (url, await self.hello(url, key: pairing.key)) } }
                for await (url, answer) in group {
                    switch answer {
                    case .mine(let name):
                        group.cancelAll()
                        return (url, name)
                    case .notMine where own.contains(url):
                        refusal = .refused("Your Mac didn't accept this iPhone. Pair it again with the code in RealBook's Listen on iPhone tab.")
                    case .tooOld:
                        refusal = .refused("Update RealBook on your Mac to connect this iPhone.")
                    default:
                        break
                    }
                }
                return nil
            }
            if let (url, name) = winner {
                remember(url, name: name)
                return url
            }
            if round == 0 { try? await Task.sleep(for: .seconds(1.5)) }  // the network may announce it by then
        }
        working = nil
        throw refusal ?? MacError.unreachable
    }

    /// Next time, straight to the address that worked.
    private func remember(_ url: URL, name: String?) {
        working = url
        lastWorked = Date()
        guard var p = pairing, let host = url.host, let port = url.port else { return }
        // Where it was reached by name, the name is the address to keep.
        if host.hasSuffix(".local") {
            guard p.macName != host else { return }
            p.macName = name ?? host
        } else {
            p.address = "\(host):\(port)"
            p.macName = name ?? p.macName
        }
        if p != pairing {
            pairing = p
            savePairing()
        }
    }

    /// Sends a request to the Mac, wherever it is now.
    func data(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [],
              timeout: TimeInterval = 6) async throws -> Data {
        for _ in 0..<2 {
            let base = try await base()
            do {
                let r = request(path, method: method, body: body, query: query, timeout: timeout, base: base)
                let (data, response) = try await session.data(for: r)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                lastWorked = Date()
                if status == 403 { throw MacError.refused("Your Mac didn't accept this iPhone. Pair it again with the code in RealBook's Listen on iPhone tab.") }
                guard (200..<300).contains(status) else {
                    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                    throw MacError.refused(detail ?? "Your Mac answered with an error (\(status)).")
                }
                return data
            } catch let error as MacError {
                throw error
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                working = nil  // it's gone from there: look for it again
            }
        }
        throw MacError.unreachable
    }

    func books() async throws -> [RemoteBook] {
        try JSONDecoder().decode([RemoteBook].self, from: await data("api/phone/books"))
    }

    func book(_ id: String) async throws -> MacBook {
        try JSONDecoder().decode(MacBook.self, from: await data("api/books/\(id)"))
    }

    /// What to save for listening away from the Mac; asks it to make the next hours too.
    func ahead(_ id: String) async throws -> Kept.Manifest {
        try JSONDecoder().decode(Kept.Manifest.self, from: await data("api/books/\(id)/ahead", method: "POST", timeout: 30))
    }

    /// Throws away how a line was read; it's read anew when next asked for.
    func readAgain(chapter: Int, segment: Int, of id: String) async throws {
        _ = try await data("api/books/\(id)/chapters/\(chapter)/segments/\(segment)/again", method: "POST")
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
        guard pairing != nil else { throw MacError.notPaired }
        let reporter = ProgressReporter(progress)
        do {
            let (file, response) = try await URLSession.shared.download(for: request(path, base: try await base()), delegate: reporter)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw MacError.refused("Your Mac couldn't send the file (\(status)).") }
            lastWorked = Date()
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
        } catch is URLError {
            working = nil
            throw MacError.unreachable
        }
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
