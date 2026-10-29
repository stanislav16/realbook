import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays a book in the background and from the lock screen, either from its offline copy on this
/// iPhone or live from the Mac, one line at a time, the way Safari does. Switching between the two
/// carries on from the same line.
@MainActor
@Observable
final class Player {
    enum Mode: String { case offline, live }

    /// A line as it's shown: its text, who says it (nil: the narrator) and their colour.
    struct Spoken: Hashable {
        var text: String
        var speaker: String?
        var color: String?
    }

    private(set) var bookID: String?
    private(set) var title = ""
    private(set) var mode = Mode.offline
    private(set) var playing = false
    private(set) var loading = false
    private(set) var problem: String?
    private(set) var chapterTitles: [String] = []
    private(set) var chapter = 0
    private(set) var before: Spoken?
    private(set) var current: Spoken?
    private(set) var after: Spoken?
    var speed: Float = UserDefaults.standard.object(forKey: "speed") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "speed")
            if playing { offline.rate = speed; live?.rate = speed }
            updateNowPlaying()
        }
    }

    static let speeds: [Float] = [0.8, 1, 1.15, 1.3, 1.5, 1.75, 2]

    private var library: Library?
    private var artwork: UIImage?

    // MARK: offline copy
    private let offline = AVPlayer()
    private var timeline: Timeline?
    private(set) var ms = 0
    private var lastSaved = Date.distantPast

    // MARK: live from the Mac
    private var macBook: MacBook?
    private var segments: [MacChapter.Segment] = []
    private var segment = 0
    private var live: AVAudioPlayer?
    private let finished = Finished()
    private var lines: [String: Data] = [:]  // "chapter:segment" -> audio
    private var fetching: [String: Task<Data, Error>] = [:]
    private var playTask: Task<Void, Never>?
    private var gapTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        offline.automaticallyWaitsToMinimizeStalling = false
        offline.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated { if type == .began { self?.pause() } }
        }
        finished.done = { [weak self] in self?.lineEnded() }
        setUpRemoteCommands()
    }

    // MARK: - choosing what to play

    var hasOfflineCopy: Bool { bookID.flatMap { library?.book($0) } != nil }

    /// Opens a book: its offline copy if this iPhone has one, else live from the Mac.
    func open(_ id: String, library: Library) {
        self.library = library
        guard bookID != id else { return }
        stopAll()
        bookID = id
        problem = nil
        artwork = nil
        Task { artwork = await library.cover(id); updateNowPlaying() }
        if let book = library.book(id), let t = library.timeline(id), !t.lines.isEmpty {
            title = book.title
            startOffline(book, t, at: book.positionMs)
        } else {
            // Not on this iPhone: live from the Mac (asking it where the reader is, if not known yet).
            mode = .live
            title = library.remoteBook(id)?.title ?? ""
            Task {
                if library.remoteBook(id) == nil { await library.sync() }
                guard bookID == id else { return }
                let at = library.remoteBook(id)?.position
                await startLive(at: at?.chapter ?? 0, segment: at?.segment ?? 0)
            }
        }
    }

    /// Switches between the offline copy and live, carrying on from the same line.
    func switchTo(_ new: Mode) {
        guard new != mode, let id = bookID, let library else { return }
        let wasPlaying = playing
        if new == .live {
            let spot = timeline.map { $0.macPosition(at: ms) } ?? (chapter: 0, segment: 0)
            stopAll()
            Task {
                await startLive(at: spot.chapter, segment: spot.segment)
                if wasPlaying { play() }
            }
        } else if let book = library.book(id), let t = library.timeline(id), !t.lines.isEmpty {
            let at = t.ms(chapter: chapter, segment: segment)
            stopAll()
            startOffline(book, t, at: at)
            if wasPlaying { play() }
        }
    }

    private func stopAll() {
        pause()
        offline.replaceCurrentItem(with: nil)
        timeline = nil
        playTask?.cancel()
        gapTask?.cancel()
        live?.stop()
        live = nil
        macBook = nil
        segments = []
        lines = [:]
        fetching.values.forEach { $0.cancel() }
        fetching = [:]
    }

    private func startOffline(_ book: LocalBook, _ t: Timeline, at position: Int) {
        mode = .offline
        timeline = t
        chapterTitles = t.chapters.map(\.title)
        offline.replaceCurrentItem(with: AVPlayerItem(url: Library.audio(of: book.id)))
        offline.currentItem?.audioTimePitchAlgorithm = .timeDomain
        seek(to: position, save: false)
    }

    private func startLive(at chapter: Int, segment: Int) async {
        guard let id = bookID, let library else { return }
        mode = .live
        loading = true
        defer { loading = false }
        do {
            let book = try await library.mac.book(id)
            guard bookID == id else { return }
            macBook = book
            title = book.title
            chapterTitles = book.toc.map(\.title)
            try await loadChapter(chapter, at: segment)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadChapter(_ n: Int, at seg: Int) async throws {
        guard let id = bookID else { return }
        let ch = try await library!.mac.chapter(n, of: id)
        guard bookID == id, mode == .live else { return }
        chapter = n
        segments = ch.segments
        segment = max(0, min(seg, segments.count - 1))
        showLiveLine()
        updateNowPlaying()
    }

    // MARK: - controls

    func toggle() { playing ? pause() : play() }

    func play() {
        problem = nil
        try? AVAudioSession.sharedInstance().setActive(true)
        switch mode {
        case .offline:
            guard offline.currentItem != nil else { return }
            offline.playImmediately(atRate: speed)
            playing = true
        case .live:
            guard !segments.isEmpty else { return }
            playing = true
            playLiveLine()
        }
        updateNowPlaying()
    }

    func pause() {
        let was = playing
        playing = false
        offline.pause()
        live?.pause()
        gapTask?.cancel()
        playTask?.cancel()
        if mode == .offline { savePosition() }
        updateNowPlaying()
        if was, let library { Task { await library.sync() } }
    }

    /// Back to the start of this line, or the one before if this one only just started.
    func previousLine() {
        switch mode {
        case .offline:
            guard let t = timeline, !t.lines.isEmpty else { return }
            let i = t.lineIndex(at: ms)
            seek(to: t.lines[ms - t.lines[i].ms > 1500 ? i : max(0, i - 1)].ms)
        case .live:
            let restart = (live?.currentTime ?? 0) > 1.5
            goToLine(restart ? segment : segment - 1)
        }
    }

    func nextLine() {
        switch mode {
        case .offline:
            guard let t = timeline, !t.lines.isEmpty else { return }
            let i = t.lineIndex(at: ms)
            if i + 1 < t.lines.count { seek(to: t.lines[i + 1].ms) }
        case .live:
            goToLine(segment + 1)
        }
    }

    func skip(seconds: Int) {
        if mode == .offline { seek(to: ms + seconds * 1000) } else if seconds < 0 { previousLine() } else { nextLine() }
    }

    func goTo(chapter n: Int) {
        guard chapterTitles.indices.contains(n) else { return }
        switch mode {
        case .offline:
            if let c = timeline?.chapters[n] { seek(to: c.ms) }
        case .live:
            let wasPlaying = playing
            pause()
            Task {
                do { try await loadChapter(n, at: 0) } catch { problem = error.localizedDescription }
                saveLivePosition()
                if wasPlaying { play() }
            }
        }
    }

    /// How far through: the whole book for the offline copy, the chapter when live.
    var progress: Double {
        switch mode {
        case .offline: Double(ms) / Double(max(1, timeline?.ms ?? 1))
        case .live: segments.count > 1 ? Double(segment) / Double(segments.count - 1) : 0
        }
    }

    /// Jumps to a point (0…1) on the progress bar.
    func scrub(to fraction: Double) {
        switch mode {
        case .offline: seek(to: Int(fraction * Double(timeline?.ms ?? 0)))
        case .live: goToLine(Int((fraction * Double(max(0, segments.count - 1))).rounded()))
        }
    }

    /// What the progress bar's two ends say.
    func progressLabels(at fraction: Double? = nil) -> (String, String) {
        switch mode {
        case .offline:
            let total = timeline?.ms ?? 0
            let at = fraction.map { Int($0 * Double(total)) } ?? ms
            return (Self.time(at), "−" + Self.time(total - at))
        case .live:
            let n = max(1, segments.count)
            let at = fraction.map { Int(($0 * Double(n - 1)).rounded()) } ?? segment
            return ("Line \(at + 1)", "of \(n)")
        }
    }

    static func time(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - offline copy

    func seek(to target: Int, save: Bool = true) {
        let clamped = max(0, min(target, max(0, (timeline?.ms ?? 0) - 500)))
        ms = clamped
        updateOfflineLine()
        offline.seek(to: CMTime(value: CMTimeValue(clamped), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        if save { savePosition() }
        updateNowPlaying()
    }

    /// The position moved on the Mac: follow it, unless this iPhone is playing.
    func follow(_ book: LocalBook) {
        guard book.id == bookID, !playing, mode == .offline else { return }
        seek(to: book.positionMs, save: false)
    }

    private func tick(_ time: CMTime) {
        guard playing, mode == .offline, time.isNumeric else { return }
        ms = Int(time.seconds * 1000)
        updateOfflineLine()
        if Date().timeIntervalSince(lastSaved) > 5 { savePosition() }
    }

    private func updateOfflineLine() {
        guard let t = timeline, !t.lines.isEmpty else { return }
        let i = t.lineIndex(at: ms)
        let spoken = { (l: Timeline.Line) in
            Spoken(text: l.text, speaker: l.speaker.map { t.speakers[$0] ?? $0 }, color: l.speaker.flatMap { t.colors?[$0] })
        }
        let now = spoken(t.lines[i])
        if now != current {
            current = now
            before = i > 0 ? spoken(t.lines[i - 1]) : nil
            after = i + 1 < t.lines.count ? spoken(t.lines[i + 1]) : nil
            segment = max(0, t.lines[i].segment)
        }
        let c = t.chapterIndex(at: ms)
        if c != chapter {
            chapter = c
            updateNowPlaying()
        }
    }

    private func savePosition() {
        guard let bookID, mode == .offline else { return }
        lastSaved = Date()
        library?.setPosition(ms, of: bookID)
    }

    // MARK: - live

    private func key(_ c: Int, _ s: Int) -> String { "\(c):\(s)" }

    /// A line's audio from the Mac, fetched once (and ahead of time while listening).
    private func audio(chapter c: Int, segment s: Int, ahead: Bool) async throws -> Data {
        let k = key(c, s)
        if let data = lines[k] { return data }
        if let task = fetching[k] { return try await task.value }
        guard let id = bookID, let mac = library?.mac else { throw MacError.notPaired }
        let task = Task { try await mac.line(s, chapter: c, of: id, ahead: ahead) }
        fetching[k] = task
        defer { fetching[k] = nil }
        let data = try await task.value
        lines[k] = data
        return data
    }

    private func playLiveLine() {
        playTask?.cancel()
        let c = chapter, s = segment
        playTask = Task {
            loading = lines[key(c, s)] == nil
            do {
                let data = try await audio(chapter: c, segment: s, ahead: false)
                loading = false
                guard playing, !Task.isCancelled, c == chapter, s == segment else { return }
                let p = try AVAudioPlayer(data: data)
                p.enableRate = true
                p.rate = speed
                p.delegate = finished
                live = p
                p.play()
                fetchAhead()
            } catch is CancellationError {
            } catch {
                loading = false
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                pause()
            }
        }
    }

    /// Asks the Mac for the next few lines now, so each is ready when its turn comes.
    private func fetchAhead() {
        let c = chapter
        for s in segment + 1..<min(segments.count, segment + 5) where lines[key(c, s)] == nil && fetching[key(c, s)] == nil {
            Task { _ = try? await audio(chapter: c, segment: s, ahead: true) }
        }
        // Keep only what's near, so a long session doesn't hold a whole book.
        lines = lines.filter { k, _ in
            let p = k.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 && p[0] == c && p[1] >= segment - 2
        }
    }

    private func lineEnded() {
        guard playing, mode == .live else { return }
        let samePara = segment + 1 < segments.count && segments[segment + 1].para == segments[segment].para
        let gap = (samePara ? 0.09 : 0.32) / Double(speed)  // the pauses the Mac's player leaves
        gapTask = Task {
            try? await Task.sleep(for: .seconds(gap))
            guard !Task.isCancelled, playing else { return }
            if segment + 1 < segments.count {
                segment += 1
                showLiveLine()
                saveLivePosition()
                playLiveLine()
            } else if chapter + 1 < chapterTitles.count {
                do {
                    try await loadChapter(chapter + 1, at: 0)
                    saveLivePosition()
                    playLiveLine()
                } catch {
                    problem = error.localizedDescription
                    pause()
                }
            } else {
                pause()
            }
        }
    }

    private func goToLine(_ s: Int) {
        guard mode == .live, !segments.isEmpty else { return }
        gapTask?.cancel()
        live?.stop()
        segment = max(0, min(s, segments.count - 1))
        showLiveLine()
        saveLivePosition()
        if playing { playLiveLine() }
    }

    private func showLiveLine() {
        guard segments.indices.contains(segment) else { return }
        let names = Dictionary(uniqueKeysWithValues: (macBook?.cast ?? []).map { ($0.id, $0.name) })
        let colors = macBook?.colors ?? [:]
        let spoken = { (s: MacChapter.Segment) in
            let who = s.kind == "dialogue" ? s.speaker : nil
            return Spoken(text: s.text, speaker: who.map { names[$0] ?? $0 }, color: who.flatMap { colors[$0] })
        }
        current = spoken(segments[segment])
        before = segment > 0 ? spoken(segments[segment - 1]) : nil
        after = segment + 1 < segments.count ? spoken(segments[segment + 1]) : nil
    }

    private func saveLivePosition() {
        saveTask?.cancel()
        let c = chapter, s = segment
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let id = bookID else { return }
            library?.setLivePosition(chapter: c, segment: s, of: id)
        }
    }

    // MARK: - lock screen

    private func updateNowPlaying() {
        guard bookID != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitles.indices.contains(chapter) ? chapterTitles[chapter] : title,
            MPMediaItemPropertyAlbumTitle: title,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if mode == .offline, let t = timeline {
            info[MPMediaItemPropertyArtist] = t.author
            info[MPMediaItemPropertyPlaybackDuration] = Double(t.ms) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(ms) / 1000
        } else if let b = macBook {
            info[MPMediaItemPropertyArtist] = b.author
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let c = MPRemoteCommandCenter.shared()
        c.changePlaybackPositionCommand.isEnabled = mode == .offline
    }

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(seconds: -15) }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(seconds: 30) }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: Int(e.positionTime * 1000)) }
            return .success
        }
    }
}

/// Tells the player when a live line has finished playing.
private final class Finished: NSObject, AVAudioPlayerDelegate {
    var done: (@MainActor () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.done?() }
    }
}
