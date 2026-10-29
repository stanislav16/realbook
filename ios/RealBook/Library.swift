import Foundation
import Observation
import UIKit

/// The books kept on this iPhone, the Mac's books when it can be reached, and keeping the reading
/// position in step between the two: whichever was used last wins.
@MainActor
@Observable
final class Library {
    private(set) var books: [LocalBook] = []
    private(set) var remote: [RemoteBook] = []
    private(set) var reachable = false
    private(set) var lastError: String?
    var downloads: [String: Double] = [:]  // book id -> progress

    let mac = MacClient.shared
    var paired: Bool { mac.pairing != nil }

    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Books")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // big, and the Mac can always make it again
        var u = url
        try? u.setResourceValues(values)
        return url
    }()

    static func folder(of id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    static func audio(of id: String) -> URL { folder(of: id).appendingPathComponent("book.m4b") }
    static func cover(of id: String) -> URL { folder(of: id).appendingPathComponent("cover.jpg") }
    static func timelineURL(of id: String) -> URL { folder(of: id).appendingPathComponent("timeline.json") }
    private static func meta(of id: String) -> URL { folder(of: id).appendingPathComponent("book.json") }

    private var timelines: [String: Timeline] = [:]

    init() { load() }

    private func load() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        books = ids.compactMap { id in
            guard let data = try? Data(contentsOf: Self.meta(of: id)) else { return nil }
            return try? JSONDecoder().decode(LocalBook.self, from: data)
        }.sorted { $0.positionUpdated > $1.positionUpdated }
    }

    private func save(_ book: LocalBook) {
        if let i = books.firstIndex(where: { $0.id == book.id }) { books[i] = book } else { books.append(book) }
        try? JSONEncoder().encode(book).write(to: Self.meta(of: book.id), options: .atomic)
    }

    func book(_ id: String) -> LocalBook? { books.first { $0.id == id } }
    func remoteBook(_ id: String) -> RemoteBook? { remote.first { $0.id == id } }

    /// A book's cover: from its offline copy, or fetched from the Mac once and kept.
    func cover(_ id: String) async -> UIImage? {
        if let image = UIImage(contentsOfFile: Self.cover(of: id).path) { return image }
        let cached = Self.coverCache.appendingPathComponent("\(id).jpg")
        if let image = UIImage(contentsOfFile: cached.path) { return image }
        guard remoteBook(id)?.cover != nil, let data = try? await mac.cover(id) else { return nil }
        try? data.write(to: cached)
        return UIImage(data: data)
    }

    private static let coverCache: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func timeline(_ id: String) -> Timeline? {
        if let t = timelines[id] { return t }
        guard let data = try? Data(contentsOf: Self.timelineURL(of: id)),
              let t = try? JSONDecoder().decode(Timeline.self, from: data) else { return nil }
        timelines[id] = t
        return t
    }

    // MARK: - position

    /// Where the reader is now (called by the player as it plays).
    func setPosition(_ ms: Int, of id: String) {
        guard var b = book(id) else { return }
        b.positionMs = ms
        b.positionUpdated = Date().timeIntervalSince1970
        save(b)
    }

    /// Where the reader is when listening live: tells the Mac, and moves the offline copy (if there
    /// is one) to the same line, so switching between the two carries on from here.
    func setLivePosition(chapter: Int, segment: Int, of id: String) {
        let now = Date().timeIntervalSince1970
        if var b = book(id), let t = timeline(id), !t.lines.isEmpty {
            b.positionMs = t.ms(chapter: chapter, segment: segment)
            b.positionUpdated = now
            save(b)
        }
        if let i = remote.firstIndex(where: { $0.id == id }) {
            remote[i].position = MacPosition(chapter: chapter, segment: segment, updated: now)
        }
        Task { _ = try? await mac.send(position: MacPosition(chapter: chapter, segment: segment, updated: now), book: id) }
    }

    /// Sends this iPhone's newer positions to the Mac and takes the Mac's newer ones. Returns the ids
    /// of books whose position moved here.
    @discardableResult
    func sync() async -> Set<String> {
        guard paired else { return [] }
        do {
            remote = try await mac.books()
            reachable = true
            lastError = nil
        } catch {
            reachable = false
            lastError = error.localizedDescription
            return []
        }
        var moved = Set<String>()
        for r in remote {
            guard var b = book(r.id), let t = timeline(r.id), !t.lines.isEmpty else { continue }
            let theirs = r.position.updated ?? 0
            if b.positionUpdated > theirs + 1 {
                let (chapter, segment) = t.macPosition(at: b.positionMs)
                let mine = MacPosition(chapter: chapter, segment: segment, updated: b.positionUpdated)
                if let newer = try? await mac.send(position: mine, book: r.id), let when = newer.updated, when > b.positionUpdated {
                    b.positionMs = t.ms(chapter: newer.chapter, segment: newer.segment)
                    b.positionUpdated = when
                    save(b)
                    moved.insert(r.id)
                }
            } else if theirs > b.positionUpdated + 1 {
                let ms = t.ms(chapter: r.position.chapter, segment: r.position.segment)
                if t.macPosition(at: ms) != t.macPosition(at: b.positionMs) {
                    b.positionMs = ms
                    moved.insert(r.id)
                }
                b.positionUpdated = theirs
                save(b)
            }
        }
        return moved
    }

    // MARK: - downloading

    /// The Mac's offline copy is newer than the one on this iPhone.
    func hasUpdate(_ r: RemoteBook) -> Bool {
        guard let b = book(r.id), let made = r.export.made else { return false }
        return r.export.ready && made > b.made + 1
    }

    func download(_ r: RemoteBook) async {
        guard downloads[r.id] == nil, r.export.ready else { return }
        downloads[r.id] = 0
        defer { downloads[r.id] = nil }
        let folder = Self.folder(of: r.id)
        // When replacing a copy, where the reader was in it, in the Mac's terms: the new copy's lines
        // may start at other times.
        let old = book(r.id)
        let oldSpot = old.flatMap { o in timeline(r.id).flatMap { $0.lines.isEmpty ? nil : $0.macPosition(at: o.positionMs) } }
        let staging = Self.folder.appendingPathComponent(".\(r.id)-download", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try await mac.download("api/books/\(r.id)/export/timeline", to: staging.appendingPathComponent("timeline.json")) { _ in }
            var hasCover = false
            if r.cover != nil {
                hasCover = (try? await mac.download("api/books/\(r.id)/cover", to: staging.appendingPathComponent("cover.jpg")) { _ in }) != nil
            }
            try await mac.download("api/books/\(r.id)/export/file", to: staging.appendingPathComponent("book.m4b")) { [weak self] p in
                self?.downloads[r.id] = p
            }
            let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: staging.appendingPathComponent("timeline.json")))
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: staging, to: folder)
            timelines[r.id] = timeline
            var b = LocalBook(id: r.id, title: r.title, author: r.author, made: r.export.made ?? timeline.made,
                              bytes: r.export.bytes ?? 0, hasCover: hasCover, durationMs: timeline.ms)
            // Start where the reader is: here or on the Mac, whichever is newer.
            let theirs = r.position.updated ?? 0
            if let old, let oldSpot, old.positionUpdated >= theirs {
                b.positionMs = timeline.ms(chapter: oldSpot.chapter, segment: oldSpot.segment)
                b.positionUpdated = old.positionUpdated
            } else {
                b.positionMs = timeline.ms(chapter: r.position.chapter, segment: r.position.segment)
                b.positionUpdated = theirs
            }
            save(b)
            books.sort { $0.positionUpdated > $1.positionUpdated }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            lastError = error.localizedDescription
        }
    }

    func makeOfflineCopy(_ r: RemoteBook) async {
        do {
            try await mac.startExport(r.id)
            await sync()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: Self.folder(of: id))
        books.removeAll { $0.id == id }
        timelines[id] = nil
    }
}
