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
    var finished: Bool?
    var opened: Double?
    var chapters: Int?
    var export: Export
}

/// Where each line of an offline copy starts, with its text (export/timeline.json).
struct Timeline: Codable {
    struct Chapter: Codable {
        var ms: Int
        var title: String
        var chapter: Int
    }

    /// One spoken line: [start ms, chapter, segment (-1: the chapter's title), speaker id or null, text,
    /// paragraph, quote]. Copies made before the last two came along leave them out.
    struct Line: Codable {
        var ms: Int
        var chapter: Int
        var segment: Int
        var speaker: String?
        var text: String
        var para: Int?
        var q: Int?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            ms = try c.decode(Int.self)
            chapter = try c.decode(Int.self)
            segment = try c.decode(Int.self)
            speaker = try c.decodeIfPresent(String.self)
            text = try c.decode(String.self)
            if !c.isAtEnd { para = try c.decodeIfPresent(Int.self) }
            if !c.isAtEnd { q = try c.decodeIfPresent(Int.self) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(ms)
            try c.encode(chapter)
            try c.encode(segment)
            try c.encode(speaker)
            try c.encode(text)
            try c.encode(para)
            try c.encode(q)
        }
    }

    /// Lines carry their paragraph (newer copies), so the page can be laid out as on the Mac.
    var hasParagraphs: Bool { lines.first { $0.segment >= 0 }?.para != nil }

    var made: Double
    var ms: Int
    var title: String
    var author: String
    var chapters: [Chapter]
    var speakers: [String: String]
    var colors: [String: String]?  // speaker id -> "#rrggbb", as on the Mac
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

/// A book's details on the Mac (GET /api/books/{id}), for listening live.
struct MacBook: Codable {
    struct Member: Codable {
        var id: String
        var name: String
        var summary: String?
        var lines: Int?
        var designed_from: String?
        var voice: String?
        var rate: Int?
        var pitch_shift: Int?
    }
    struct Narrator: Codable {
        var designed_from: String?
        var voice: String?
        var rate: Int?
        var pitch_shift: Int?
    }
    struct Entry: Codable { var title: String; var section: String?; var segments: Int }

    var id: String
    var title: String
    var author: String
    var cover: String?
    var position: MacPosition
    var narrator: Narrator?
    var cast: [Member]
    var toc: [Entry]

    /// The speakers' colours: their place in the cast picks one, the same way the Mac does.
    var colors: [String: String] {
        Dictionary(uniqueKeysWithValues: cast.enumerated().map { ($1.id, speakerPalette[$0 % speakerPalette.count]) })
    }
}

/// The same colours as PALETTE in the Mac app.
let speakerPalette = ["#d9480f", "#1c7ed6", "#2b8a3e", "#9c36b5", "#d6336c", "#0c8599", "#a0620a", "#5f3dc4",
                      "#5c940d", "#e03131", "#087f5b", "#7048e8"]

/// One chapter's text on the Mac (GET /api/books/{id}/chapters/{n}).
struct MacChapter: Codable {
    struct Segment: Codable {
        var id: Int
        var kind: String
        var text: String
        var para: Int
        var q: Int?
        var speaker: String?
    }

    var title: String
    var section: String?
    var segments: [Segment]
}

/// A line as the reading page shows it, from the Mac's chapter or an offline copy's timeline.
struct PageLine: Equatable {
    var segment: Int
    var text: String
    var para: Int
    var dialogue: Bool
    var q: Int?
    var speaker: String?  // the character's id
}

/// Someone with a voice in the book: the cast sheet, the speaker picker and the page's labels.
struct CastMember: Identifiable, Equatable {
    var id: String
    var name: String
    var color: String?
    var summary: String?
    var lines: Int?
    var voice: String?  // how the voice was described when it was made
    var sample: VoiceSample?
}

/// What the Mac needs to say something in a character's voice.
struct VoiceSample: Equatable {
    var voice: String
    var rate: Int
    var pitchShift: Int
}

/// A cover for a book without one: the same colours the Mac picks for it.
let coverGradients = [("#3d5a80", "#1d2d44"), ("#8d3b3b", "#4a1c1c"), ("#2f6f5e", "#163a31"), ("#6a4c93", "#35264a"),
                      ("#9a6b2f", "#4f3516"), ("#2f6d80", "#163843"), ("#5e6b3a", "#2f361c"), ("#7a3e65", "#3d1f33")]

/// The Mac's hash() of a title, to pick the same gradient.
func titleHash(_ s: String) -> Int {
    var h: Int32 = 0
    for scalar in s.unicodeScalars {
        h = h &* 31 &+ Int32(String(scalar).utf16.first ?? 0)
    }
    return Int(h.magnitude)
}
