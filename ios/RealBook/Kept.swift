import Foundation
import Network
import Observation

/// Finds RealBook on the local network, whatever address the Mac has on this Wi‑Fi.
@MainActor
final class MacFinder {
    private(set) var addresses: [String] = []  // "10.0.0.5:47321"
    var changed: (() -> Void)?
    private var browser: NWBrowser?
    private var asking: [NWEndpoint: NWConnection] = [:]

    func start() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: "_realbook._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.resolve(results.map(\.endpoint)) }
        }
        b.start(queue: .main)
        browser = b
    }

    /// An announced name becomes an address by connecting to it.
    private func resolve(_ endpoints: [NWEndpoint]) {
        addresses = []
        asking.values.forEach { $0.cancel() }
        asking = [:]
        for endpoint in endpoints {
            let params = NWParameters.tcp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let c = NWConnection(to: endpoint, using: params)
            c.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        if case .hostPort(let host, let port)? = c.currentPath?.remoteEndpoint {
                            let ip = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                            self?.addresses.append("\(ip):\(port)")
                            self?.changed?()
                        }
                        c.cancel()
                    case .failed, .waiting:
                        c.cancel()
                    default:
                        break
                    }
                }
            }
            asking[endpoint] = c
            c.start(queue: .main)
        }
    }
}

/// The next hours of the book being listened to, saved here line by line whenever the Mac is near,
/// so it carries on away from the Mac. Lines are saved by what they sound like, so a line that
/// changes on the Mac (another voice, a fix, Read Again) is the only one saved again.
@MainActor
@Observable
final class Kept {
    struct Manifest: Codable {
        struct Line: Codable {
            var chapter: Int
            var segment: Int
            var key: String
            var ready: Bool
            var words: Int

            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                chapter = try c.decode(Int.self)
                segment = try c.decode(Int.self)
                key = try c.decode(String.self)
                ready = try c.decode(Bool.self)
                words = try c.decode(Int.self)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.unkeyedContainer()
                try c.encode(chapter)
                try c.encode(segment)
                try c.encode(key)
                try c.encode(ready)
                try c.encode(words)
            }
        }
        struct Making: Codable {
            var state: String
            var enabled: Bool?
        }

        var lines: [Line]
        var chapters: [String: String]  // chapter -> a signature of its text and speakers
        var making: Making?
    }

    private static let root: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kept")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // big, and the Mac can always make it again
        try? url.setResourceValues(values)
        return url
    }()

    private static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private static func linesFolder(_ id: String) -> URL { folder(id).appendingPathComponent("lines", isDirectory: true) }
    private static func file(_ key: String, _ id: String) -> URL { linesFolder(id).appendingPathComponent("\(key).audio") }
    private static func chapterFile(_ n: Int, _ id: String) -> URL { folder(id).appendingPathComponent("chapter-\(n).json") }

    /// Bumps as lines are saved, for what's shown about them.
    private(set) var saved = 0
    @ObservationIgnored private var manifests: [String: Manifest] = [:]
    @ObservationIgnored private var keys: [String: [String: String]] = [:]  // book -> "chapter:segment" -> key
    @ObservationIgnored private var have: [String: Set<String>] = [:]

    private func manifest(_ id: String) -> Manifest? {
        if let m = manifests[id] { return m }
        guard let data = try? Data(contentsOf: Self.folder(id).appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        use(m, id)
        return m
    }

    private func use(_ m: Manifest, _ id: String) {
        manifests[id] = m
        keys[id] = Dictionary(m.lines.map { ("\($0.chapter):\($0.segment)", $0.key) }, uniquingKeysWith: { _, new in new })
        if have[id] == nil {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.linesFolder(id).path)) ?? []
            have[id] = Set(names.map { String($0.prefix { $0 != "." }) })
        }
    }

    func has(_ id: String) -> Bool { manifest(id) != nil }

    func book(_ id: String) -> MacBook? {
        guard let data = try? Data(contentsOf: Self.folder(id).appendingPathComponent("book.json")) else { return nil }
        return try? JSONDecoder().decode(MacBook.self, from: data)
    }

    func chapter(_ n: Int, of id: String) -> MacChapter? {
        guard let data = try? Data(contentsOf: Self.chapterFile(n, id)) else { return nil }
        return try? JSONDecoder().decode(MacChapter.self, from: data)
    }

    /// A line's audio, if it's saved here.
    func audio(chapter: Int, segment: Int, of id: String) -> Data? {
        guard manifest(id) != nil, let key = keys[id]?["\(chapter):\(segment)"], have[id]?.contains(key) == true else { return nil }
        return try? Data(contentsOf: Self.file(key, id))
    }

    /// A line played live is saved too, so it isn't fetched twice.
    func store(_ data: Data, chapter: Int, segment: Int, of id: String) {
        guard let key = keys[id]?["\(chapter):\(segment)"], have[id]?.contains(key) != true else { return }
        write(data, key, id)
    }

    private func write(_ data: Data, _ key: String, _ id: String) {
        try? FileManager.default.createDirectory(at: Self.linesFolder(id), withIntermediateDirectories: true)
        if (try? data.write(to: Self.file(key, id), options: .atomic)) != nil {
            have[id, default: []].insert(key)
            saved += 1
        }
    }

    /// These lines changed here: they're fetched from the Mac from now on.
    func forget(chapter: Int, segments: [Int], of id: String) {
        guard manifest(id) != nil else { return }
        for s in segments { keys[id]?["\(chapter):\(s)"] = nil }
        try? FileManager.default.removeItem(at: Self.chapterFile(chapter, id))
    }

    /// How much can be heard from here without the Mac: words, up to the first line not saved.
    func wordsAhead(chapter: Int, segment: Int, of id: String) -> Int {
        guard let m = manifest(id), let saved = have[id] else { return 0 }
        var words = 0
        for l in m.lines where l.chapter > chapter || (l.chapter == chapter && l.segment >= segment) {
            guard saved.contains(l.key), keys[id]?["\(l.chapter):\(l.segment)"] == l.key else { break }
            words += l.words
        }
        return words
    }

    func note(chapter: Int, segment: Int, of id: String) -> String? {
        _ = saved
        let minutes = wordsAhead(chapter: chapter, segment: segment, of: id) / 155
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min saved" : "\(minutes) min saved"
    }

    /// Takes the Mac's plan and saves what's ready of it, the next line first. Returns when all of it
    /// that's ready is here.
    func update(_ id: String, _ m: Manifest, from mac: MacClient) async throws {
        let folder = Self.folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        use(m, id)
        saved += 1
        try await mac.data("api/books/\(id)", timeout: 20).write(to: folder.appendingPathComponent("book.json"), options: .atomic)
        let signsFile = folder.appendingPathComponent("chapters.json")
        var signs = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: signsFile))) ?? [:]
        for (n, sign) in m.chapters {
            guard let chapter = Int(n), signs[n] != sign || !FileManager.default.fileExists(atPath: Self.chapterFile(chapter, id).path) else { continue }
            try await mac.data("api/books/\(id)/chapters/\(chapter)", timeout: 20).write(to: Self.chapterFile(chapter, id), options: .atomic)
            signs[n] = sign
            try JSONEncoder().encode(signs).write(to: signsFile, options: .atomic)
        }
        for line in m.lines where line.ready && have[id]?.contains(line.key) != true {
            try Task.checkCancellation()
            write(try await mac.line(line.segment, chapter: line.chapter, of: id, ahead: true), line.key, id)
        }
        // Lines no longer wanted: passed, or changed on the Mac.
        let wanted = Set(m.lines.map(\.key))
        for key in have[id] ?? [] where !wanted.contains(key) {
            try? FileManager.default.removeItem(at: Self.file(key, id))
            have[id]?.remove(key)
        }
        trim(keeping: id)
    }

    /// At most the book being listened to and the one before.
    private func trim(keeping id: String) {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let newest = folders.sorted {
            let date = { (u: URL) in (try? fm.attributesOfItem(atPath: u.appendingPathComponent("manifest.json").path)[.modificationDate] as? Date) ?? .distantPast }
            return date($0) > date($1)
        }
        for old in newest.filter({ $0.lastPathComponent != id }).dropFirst(1) {
            try? fm.removeItem(at: old)
            let gone = old.lastPathComponent
            manifests[gone] = nil
            keys[gone] = nil
            have[gone] = nil
        }
    }
}
