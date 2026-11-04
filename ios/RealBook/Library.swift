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
    let kept = Kept()
    var paired: Bool { mac.pairing != nil }
    /// The book open in the player: its next hours are the ones saved here.
    var listening: String?
    private var keeping: (id: String, task: Task<Void, Never>)?
    /// An offline copy is about to be removed or replaced, and once it has: the player lets go of it
    /// and then carries on from the same line.
    @ObservationIgnored var copyChanging: ((String) -> Void)?
    @ObservationIgnored var copyChanged: ((String) -> Void)?
    private var unsent = Set(UserDefaults.standard.stringArray(forKey: "unsentPositions") ?? [])  // listened to away from the Mac
    private static let remoteFile = folder.deletingLastPathComponent().appendingPathComponent("remote.json")

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

    init() {
        load()
        // Known from last time, so away from the Mac the shelf is still there.
        if let data = try? Data(contentsOf: Self.remoteFile), let saved = try? JSONDecoder().decode([RemoteBook].self, from: data) { remote = saved }
        mac.changed = { [weak self] in
            guard let self, self.paired, !self.reachable else { return }
            Task { await self.sync() }
        }
    }

    private func saveRemote() {
        try? JSONEncoder().encode(remote).write(to: Self.remoteFile, options: .atomic)
    }

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

    /// Copies made before lines carried their paragraph get a new timeline from the Mac (a small
    /// file), so their page is laid out as on the Mac.
    func refreshTimeline(_ id: String) async {
        guard let t = timeline(id), !t.hasParagraphs, reachable else { return }
        let fresh = Self.folder(of: id).appendingPathComponent("timeline-new.json")
        do {
            try await mac.download("api/books/\(id)/export/timeline", to: fresh) { _ in }
            let new = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: fresh))
            guard new.lines.count == t.lines.count, new.made == t.made else {  // a different copy: leave it for Download Update
                try? FileManager.default.removeItem(at: fresh)
                return
            }
            _ = try FileManager.default.replaceItemAt(Self.timelineURL(of: id), withItemAt: fresh)
            timelines[id] = new
        } catch {
            try? FileManager.default.removeItem(at: fresh)
        }
    }

    /// A quote was given to someone else on the Mac: show it so in the offline copy's text too.
    func setSpeaker(_ speaker: String?, chapter: Int, segments: [Int], of id: String) {
        guard var t = timeline(id) else { return }
        let changed = Set(segments)
        for i in t.lines.indices where t.lines[i].chapter == chapter && changed.contains(t.lines[i].segment) {
            t.lines[i].speaker = speaker
        }
        timelines[id] = t
        try? JSONEncoder().encode(t).write(to: Self.timelineURL(of: id), options: .atomic)
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
            saveRemote()
        }
        markUnsent(id, true)
        Task {
            if (try? await mac.send(position: MacPosition(chapter: chapter, segment: segment, updated: now), book: id)) != nil { markUnsent(id, false) }
        }
    }

    private func markUnsent(_ id: String, _ on: Bool) {
        if on { unsent.insert(id) } else { unsent.remove(id) }
        UserDefaults.standard.set(Array(unsent), forKey: "unsentPositions")
    }

    /// Where the reader got to away from the Mac; the Mac keeps whichever is newer.
    private func sendPositions() async throws {
        for id in unsent {
            guard let position = remoteBook(id)?.position else {
                markUnsent(id, false)
                continue
            }
            do {
                _ = try await mac.send(position: position, book: id)
                markUnsent(id, false)
            } catch MacError.refused {
                markUnsent(id, false)  // that book is gone from the Mac
            }
        }
    }

    /// Sends this iPhone's newer positions to the Mac and takes the Mac's newer ones. Returns the ids
    /// of books whose position moved here.
    @discardableResult
    func sync() async -> Set<String> {
        guard paired else { return [] }
        do {
            try await sendPositions()
            remote = try await mac.books()
            saveRemote()
            reachable = true
            lastError = nil
            keepCurrent()
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

    // MARK: - keeping the next hours

    /// Saves the next hours of the book being listened to, or else of the one listened to last.
    private func keepCurrent() {
        let latest = remote.filter { ($0.position.updated ?? 0) > 0 }.max { ($0.position.updated ?? 0) < ($1.position.updated ?? 0) }
        guard let id = listening ?? latest?.id, remoteBook(id)?.finished != true else { return }
        keep(id)
    }

    /// While the app is awake: asks the Mac what's ready and saves it. Books with an offline copy don't need it.
    func keep(_ id: String) {
        guard paired, book(id) == nil, keeping?.id != id else { return }
        keeping?.task.cancel()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                let making = await self?.keepOnce(id) ?? false
                try? await Task.sleep(for: .seconds(making ? 45 : 180))
            }
        }
        keeping = (id, task)
    }

    /// Whether the Mac is still making more.
    private func keepOnce(_ id: String) async -> Bool {
        do {
            try await sendPositions()
            let manifest = try await mac.ahead(id)
            reachable = true
            try await kept.update(id, manifest, from: mac)
            return manifest.making?.state == "making"
        } catch MacError.unreachable {
            reachable = false
            return false
        } catch {
            return false
        }
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
        var letGo = false
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
            // When replacing a copy, where the reader is in it now, in the Mac's terms: the new copy's
            // lines may start at other times.
            copyChanging?(r.id)
            letGo = true
            let old = book(r.id)
            let oldSpot = old.flatMap { o in self.timeline(r.id).flatMap { $0.lines.isEmpty ? nil : $0.macPosition(at: o.positionMs) } }
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
            if letGo {  // the old copy may be gone with it
                books.removeAll { $0.id == r.id && !FileManager.default.fileExists(atPath: Self.audio(of: r.id).path) }
                timelines[r.id] = nil
            }
            lastError = error.localizedDescription
        }
        if letGo { copyChanged?(r.id) }
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
        copyChanging?(id)
        try? FileManager.default.removeItem(at: Self.folder(of: id))
        books.removeAll { $0.id == id }
        timelines[id] = nil
        copyChanged?(id)
    }

    /// Unpairs: the Mac's books leave the shelf, and nothing more is asked of it.
    func forgetMac() {
        mac.unpair()
        keeping?.task.cancel()
        keeping = nil
        remote = []
        saveRemote()
        reachable = false
        lastError = nil
        unsent = []
        UserDefaults.standard.removeObject(forKey: "unsentPositions")
    }
}
