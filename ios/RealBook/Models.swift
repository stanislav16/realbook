import Foundation

/// Where the reader is in a book, as the Mac stores it: a chapter and a line in it.
struct MacPosition: Codable, Equatable {
    var chapter: Int
    var segment: Int
    var updated: Double?
}

/// A book as the Mac lists it for the iPhone (GET /api/phone/books).
struct RemoteBook: Codable, Identifiable {
    struct Export: Codable {
        var state: String
        var file: String?
        var bytes: Int64?
        var made: Double?
        var phone: Bool?
        var done: Int?
        var total: Int?
        var message: String?

        /// An offline copy the app can download (made with a timeline).
        var ready: Bool { file != nil && phone == true && state != "running" }
    }

    var id: String
    var title: String
    var author: String
    var cover: String?
    var position: MacPosition
    var progress: Double
    var export: Export
}

/// Where each line of an offline copy starts, with its text (export/timeline.json).
struct Timeline: Codable {
    struct Chapter: Codable {
        var ms: Int
        var title: String
        var chapter: Int
    }

    /// One spoken line: [start ms, chapter, segment (-1: the chapter's title), speaker id or null, text].
    struct Line: Codable {
        var ms: Int
        var chapter: Int
        var segment: Int
        var speaker: String?
        var text: String

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            ms = try c.decode(Int.self)
            chapter = try c.decode(Int.self)
            segment = try c.decode(Int.self)
            speaker = try c.decodeIfPresent(String.self)
            text = try c.decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(ms)
            try c.encode(chapter)
            try c.encode(segment)
            try c.encode(speaker)
            try c.encode(text)
        }
    }

    var made: Double
    var ms: Int
    var title: String
    var author: String
    var chapters: [Chapter]
    var speakers: [String: String]
    var lines: [Line]

    /// The line being read at `ms` (the last one that started by then).
    func lineIndex(at ms: Int) -> Int {
        var lo = 0, hi = lines.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].ms <= ms { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    func chapterIndex(at ms: Int) -> Int {
        chapters.lastIndex { $0.ms <= ms } ?? 0
    }

    /// The Mac's way of saying where `ms` is.
    func macPosition(at ms: Int) -> (chapter: Int, segment: Int) {
        guard !lines.isEmpty else { return (0, 0) }
        let line = lines[lineIndex(at: ms)]
        return (line.chapter, max(0, line.segment))  // on a chapter's title: its first line
    }

    /// Where the Mac's position starts in the audio.
    func ms(chapter: Int, segment: Int) -> Int {
        if let line = lines.first(where: { $0.chapter == chapter && $0.segment == segment }) { return line.ms }
        if let line = lines.last(where: { $0.chapter < chapter || ($0.chapter == chapter && $0.segment <= segment) }) { return line.ms }
        return 0
    }
}

/// A book kept on the iPhone.
struct LocalBook: Codable, Identifiable {
    var id: String
    var title: String
    var author: String
    var made: Double          // when its offline copy was made on the Mac
    var bytes: Int64
    var hasCover: Bool
    var positionMs: Int = 0
    var positionUpdated: Double = 0  // when the reader was last at positionMs (Unix time)
    var durationMs: Int = 0
}
