import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

/// The book open in the window, and its playing: line by line from the engine, as the page's player did.
@MainActor
@Observable
final class Reader: NSObject, AVAudioPlayerDelegate {
    static let speeds: [Float] = [0.8, 1, 1.15, 1.3, 1.5, 1.75, 2]
    enum Sleep: Equatable, Hashable { case off, minutes(Int), endOfChapter }

    let id: String
    let api: API
    private(set) var book: MacBook?
    private(set) var chapter = 0
    private(set) var segments: [MacChapter.Segment] = [] { didSet { wordsLeft = Reader.wordsLeft(segments) } }
    private(set) var title = ""
    private(set) var section = ""
    private(set) var segment = 0
    private(set) var playing = false
    private(set) var loading = false
    private(set) var revision = 0
    private(set) var sleep = Sleep.off
    private(set) var sleepEnds: Date?
    var speed: Float = 1 { didSet { UserDefaults.standard.set(speed, forKey: "speed"); audio?.rate = speed } }
    var following = true
    var problem: String?

    private var wordsLeft: [Int] = []
    private var lastSaved = 0.0
    private var audio: AVAudioPlayer?
    private var cached: [String: Data] = [:]
    private var fetching: Set<String> = []
    private var playToken = 0
    private var gap: Task<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private var followAgain: Task<Void, Never>?

    init(id: String, api: API) {
        self.id = id
        self.api = api
        super.init()
        if let saved = UserDefaults.standard.object(forKey: "speed") as? Float { speed = saved }
    }

    var progress: Double { segments.count > 1 ? Double(segment) / Double(segments.count - 1) : 0 }
    var chapterTitles: [String] { book?.toc.map(\.title) ?? [] }
    var colors: [String: String] { book?.colors ?? [:] }
    var chapterLabel: String {
        guard !section.isEmpty else { return title }
        return title.lowercased().hasPrefix(section.lowercased()) ? title : "\(section) · \(title)"
    }

    func name(of speaker: String) -> String? { book?.cast.first { $0.id == speaker }?.name }

    static func wordsLeft(_ segments: [MacChapter.Segment]) -> [Int] {
        var words = 0
        return segments.reversed().map { words += $0.text.split(whereSeparator: \.isWhitespace).count; return words }.reversed()
    }

    /// Lines not made yet have no length, so this goes by words: Dune's voices read 2.65 a second, pauses included
    /// (the iPhone's estimates use the same rate).
    func timeLeft(from line: Int) -> String {
        guard wordsLeft.indices.contains(line) else { return "" }
        let minutes = Int((Double(wordsLeft[line]) / 2.65 / Double(speed) / 60).rounded())
        return minutes < 1 ? "Under a minute left" : "About \(minutes) min left"
    }

    // MARK: - opening

    func open() async {
        do {
            let book = try await api.get(MacBook.self, "api/books/\(id)")
            self.book = book
            await load(chapter: book.position.chapter, segment: book.position.segment, play: false)
        } catch {
            problem = error.localizedDescription
        }
    }

    func load(chapter n: Int, segment s: Int = 0, play: Bool) async {
        do {
            let ch = try await api.get(MacChapter.self, "api/books/\(id)/chapters/\(n)")
            chapter = n
            title = ch.title
            section = ch.section ?? ""
            segments = ch.segments
            segment = max(0, min(s, ch.segments.count - 1))
            revision += 1
            following = true
            if play { playCurrent() } else { stopAudio() }
            if n != book?.position.chapter || s != book?.position.segment { savePosition() }
            updateNowPlaying()
        } catch {
            pause()  // not left showing Pause with nothing playing
            problem = error.localizedDescription
        }
    }

    /// Picks up where the iPhone got to, when it was listened to there meanwhile.
    func catchUp() async {
        guard !playing, let book, let fresh = try? await api.get(MacBook.self, "api/books/\(id)") else { return }
        self.book = fresh
        let p = fresh.position
        if (p.updated ?? 0) > lastSaved + 1, p.chapter != chapter || p.segment != segment {
            _ = book
            await load(chapter: p.chapter, segment: p.segment, play: false)
        }
    }

    func reloadChapter() async {
        await load(chapter: chapter, segment: segment, play: playing)
    }

    // MARK: - playing

    func toggle() { playing ? pause() : play() }

    func play() {
        guard !segments.isEmpty else { return }
        playing = true
        following = true
        if let audio, audio.play() {
            updateNowPlaying()
        } else {
            playCurrent()
        }
    }

    func pause() {
        playing = false
        gap?.cancel()
        audio?.pause()
        loading = false
        updateNowPlaying()
    }

    /// A line on. Back is to the start of this line, or the one before if this one only just started.
    func step(_ by: Int) {
        if by < 0, let audio, audio.currentTime > 1.5 {
            go(to: segment)
            return
        }
        let target = segment + by
        if target < 0 {
            if chapter > 0 { Task { await load(chapter: chapter - 1, segment: Int.max / 2, play: playing) } }
        } else if target >= segments.count {
            Task { await nextChapter() }
        } else {
            go(to: target)
        }
    }

    func go(to line: Int, play wanted: Bool? = nil) {
        segment = max(0, min(line, segments.count - 1))
        following = true
        if let wanted { playing = wanted }
        savePosition()
        if playing { playCurrent() } else { stopAudio() }
    }

    func goTo(chapter n: Int) {
        guard book?.toc.indices.contains(n) == true else { return }
        Task { await load(chapter: n, play: playing) }
    }

    private func stopAudio() {
        gap?.cancel()
        audio?.stop()
        audio = nil
        loading = false
        playToken += 1
    }

    private func playCurrent() {
        gap?.cancel()
        audio?.stop()
        audio = nil
        playing = true
        guard segments.indices.contains(segment) else { Task { await nextChapter() }; return }
        playToken += 1
        let token = playToken, line = segment, n = chapter, rev = revision
        savePosition()
        updateNowPlaying()
        loading = cached[key(n, line)] == nil
        Task {
            do {
                let data = try await fetch(n, line)
                guard token == playToken, playing, rev == revision else { return }
                let player = try AVAudioPlayer(data: data)
                player.enableRate = true
                player.rate = speed
                player.delegate = self
                #if DEBUG
                if DebugScript.silent { player.volume = 0 }
                #endif
                audio = player
                loading = false
                player.play()
                ahead()
            } catch {
                guard token == playToken else { return }
                loading = false
                playing = false
                problem = error.localizedDescription
            }
        }
    }

    private func key(_ n: Int, _ line: Int) -> String { "\(revision)/\(n)/\(line)" }

    private func fetch(_ n: Int, _ line: Int, prefetch: Bool = false) async throws -> Data {
        let k = key(n, line)
        if let data = cached[k] { return data }
        let data = try await api.data("api/books/\(id)/audio/\(n)/\(line)", query: prefetch ? ["prefetch": "1"] : [:])
        cached[k] = data
        if cached.count > 40 { cached = cached.filter { $0.key.hasPrefix("\(revision)/\(chapter)/") } }
        return data
    }

    /// Asks for the next few lines now, so each is ready when its turn comes.
    private func ahead() {
        for line in segment + 1 ..< max(segment + 1, min(segments.count, segment + 5)) {
            let k = key(chapter, line), n = chapter
            guard cached[k] == nil, !fetching.contains(k) else { continue }
            fetching.insert(k)
            Task {
                _ = try? await fetch(n, line, prefetch: true)
                fetching.remove(k)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishedLine() }
    }

    private func finishedLine() {
        guard playing else { return }
        audio = nil
        let now = segments.indices.contains(segment) ? segments[segment] : nil
        let next = segments.indices.contains(segment + 1) ? segments[segment + 1] : nil
        guard let next else { Task { await nextChapter() }; return }
        segment += 1
        let pause = next.para != now?.para ? 0.32 : 0.09
        gap = Task {
            try? await Task.sleep(for: .seconds(pause / Double(speed)))
            if !Task.isCancelled && playing { playCurrent() }
        }
    }

    private func nextChapter() async {
        let count = book?.toc.count ?? 0
        if sleep == .endOfChapter && chapter + 1 < count {
            setSleep(.off)
            playing = false
            await load(chapter: chapter + 1, play: false)
        } else if chapter + 1 < count {
            await load(chapter: chapter + 1, play: true)
        } else {
            pause()
            segment = max(0, segments.count - 1)
            savePosition()
        }
    }

    func savePosition() {
        lastSaved = Date().timeIntervalSince1970
        let body: [String: Any] = ["chapter": chapter, "segment": segment, "updated": lastSaved]
        let id = id, api = api
        Task { _ = try? await api.data("api/books/\(id)/position", method: "PUT", json: body) }
    }

    /// Scrolled away from the line being read: carries on following a little after, if it's playing.
    func scrolledAway() {
        following = false
        followAgain?.cancel()
        followAgain = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled && playing {
                    following = true
                    return
                }
            }
        }
    }

    func readAgain(_ line: Int) async {
        do {
            try await api.data("api/books/\(id)/chapters/\(chapter)/segments/\(line)/again", method: "POST")
            cached[key(chapter, line)] = nil
            go(to: line, play: true)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Gives a quote (every line of it) to someone else. Only the line being read, if it changed, is
    /// said again in the new voice, as on the iPhone.
    func setSpeaker(_ speaker: String?, line: Int) async {
        struct Reply: Decodable { var changed: [Int]; var cast: [MacBook.Member] }
        let n = chapter
        do {
            let data = try await api.data("api/books/\(id)/chapters/\(n)/segments/\(line)/speaker", method: "PUT", json: ["speaker": speaker as Any])
            let r = try JSONDecoder().decode(Reply.self, from: data)
            book?.cast = r.cast  // their line counts
            guard n == chapter else { return }
            for i in r.changed where segments.indices.contains(i) {
                segments[i].speaker = speaker
                cached[key(n, i)] = nil
            }
            let loadingLine = loading
            // The page shows the new speakers; the lines that didn't change stay fetched.
            let old = "\(revision)/"
            revision += 1
            cached = Dictionary(uniqueKeysWithValues: cached.compactMap { k, v in k.hasPrefix(old) ? ("\(revision)/" + k.dropFirst(old.count), v) : nil })
            if playing && (r.changed.contains(segment) || loadingLine) { playCurrent() }
        } catch {
            problem = error.localizedDescription
        }
    }

    func refreshBook() async {
        if let book = try? await api.get(MacBook.self, "api/books/\(id)") { self.book = book; cached.removeAll(); revision += 1 }
    }

    // MARK: - sleep

    func setSleep(_ value: Sleep) {
        sleep = value
        sleepTimer?.cancel()
        sleepEnds = nil
        if case .minutes(let m) = value {
            let ends = Date().addingTimeInterval(Double(m) * 60)
            sleepEnds = ends
            sleepTimer = Task {
                try? await Task.sleep(for: .seconds(ends.timeIntervalSinceNow))
                if !Task.isCancelled {
                    pause()
                    setSleep(.off)
                }
            }
        }
    }

    // MARK: - the system's controls

    /// The book was closed: it leaves Control Center's Now Playing.
    func disconnectSystemControls() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand] {
            command.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func connectSystemControls() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand] {
            command.removeTarget(nil)  // the last book's
        }
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.step(1); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.step(-1); return .success }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [MPMediaItemPropertyTitle: chapterLabel, MPMediaItemPropertyAlbumTitle: book?.title ?? "", MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(speed) : 0]
        if let author = book?.author, !author.isEmpty { info[MPMediaItemPropertyArtist] = author }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }
}
