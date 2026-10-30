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
    enum Sleep: Hashable { case off, minutes(Int), endOfChapter }

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
    private(set) var current: Spoken?
    /// The chapter as the reading page shows it, and the line being read in it.
    private(set) var page: [PageLine] = []
    private(set) var pageTitle = ""
    private(set) var pageSection: String?
    private(set) var segment = 0
    /// Bumps when the page's text or speakers change, so the page lays itself out again.
    private(set) var revision = 0
    private(set) var notice: String?
    private(set) var sleep = Sleep.off
    private(set) var sleepEnds: Date?
    private(set) var sampling: String?  // whose voice sample is loading or playing
    var speed: Float = UserDefaults.standard.object(forKey: "speed") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "speed")
            if playing { offline.rate = speed; live?.rate = speed }
            updateNowPlaying()
        }
    }

    static let speeds: [Float] = [0.8, 1, 1.15, 1.3, 1.5, 1.75, 2]

    #if DEBUG
    /// `-silent YES`: plays everything at no volume, for trying playback without making a sound.
    private static let volume: Float = UserDefaults.standard.bool(forKey: "silent") ? 0 : 1
    #else
    private static let volume: Float = 1
    #endif

    private var library: Library?
    private var artwork: UIImage?

    // MARK: offline copy
    private let offline = AVPlayer()
    private var timeline: Timeline?
    private(set) var ms = 0
    private var lastSaved = Date.distantPast

    // MARK: live from the Mac
    private var macBook: MacBook?  // also fetched for an offline copy, for its cast, when the Mac is near
    private var segments: [MacChapter.Segment] = []
    private var live: AVAudioPlayer?
    private var liveKey = ""       // the line `live` is playing, to carry on with it after a pause
    private var playWhenLoaded = false
    private var sampler: AVAudioPlayer?
    private var sleepTask: Task<Void, Never>?
    private let finished = Finished()
    private var lines: [String: Data] = [:]  // "chapter:segment" -> audio
    private var fetching: [String: Task<Data, Error>] = [:]
    private var playTask: Task<Void, Never>?
    private var gapTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        offline.automaticallyWaitsToMinimizeStalling = false
        offline.volume = Self.volume
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
    func open(_ id: String, library: Library, play start: Bool = false) {
        self.library = library
        guard bookID != id else {
            if start && !playing { play() }
            return
        }
        stopAll()
        bookID = id
        problem = nil
        notice = nil
        artwork = nil
        playWhenLoaded = start
        Task { artwork = await library.cover(id); updateNowPlaying() }
        if let book = library.book(id), let t = library.timeline(id), !t.lines.isEmpty {
            title = book.title
            startOffline(book, t, at: book.positionMs)
            if start { play() }
            Task {
                await library.refreshTimeline(id)  // older copies: their page's paragraphs
                if bookID == id, mode == .offline, let fresh = library.timeline(id), fresh.hasParagraphs, timeline?.hasParagraphs == false {
                    timeline = fresh
                    buildOfflinePage()
                }
                await loadCast(id)
            }
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
        liveKey = ""
        macBook = nil
        page = []
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
        chapter = -1  // so the page is made for wherever this starts
        seek(to: position, save: false)
    }

    /// The Mac's details of a book that plays from its offline copy: who's in it, and how they sound.
    private func loadCast(_ id: String) async {
        guard macBook == nil, let library, library.reachable, let book = try? await library.mac.book(id), bookID == id else { return }
        macBook = book
        if mode == .offline { buildOfflinePage() }
    }

    /// The reading page for the offline copy's chapter, from its timeline.
    private func buildOfflinePage() {
        guard let t = timeline, t.chapters.indices.contains(chapter) else { return }
        let ci = t.chapters[chapter].chapter
        var n = 0
        page = t.lines.filter { $0.chapter == ci && $0.segment >= 0 }.map { l in
            n += 1
            return PageLine(segment: l.segment, text: l.text, para: l.para ?? n, dialogue: l.q != nil || l.speaker != nil, q: l.q, speaker: l.speaker)
        }
        pageTitle = t.chapters[chapter].title
        pageSection = macBook.flatMap { $0.toc.indices.contains(ci) ? $0.toc[ci].section : nil }.flatMap { $0.isEmpty || $0 == pageTitle ? nil : $0 }
        revision += 1
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
            if playWhenLoaded { play() }
        } catch {
            problem = error.localizedDescription
        }
        playWhenLoaded = false
    }

    private func loadChapter(_ n: Int, at seg: Int) async throws {
        guard let id = bookID else { return }
        let ch = try await library!.mac.chapter(n, of: id)
        guard bookID == id, mode == .live else { return }
        chapter = n
        segments = ch.segments
        segment = max(0, min(seg, segments.count - 1))
        page = segments.map { PageLine(segment: $0.id, text: $0.text, para: $0.para, dialogue: $0.kind == "dialogue", q: $0.q, speaker: $0.speaker) }
        pageTitle = ch.title
        pageSection = ch.section.flatMap { $0.isEmpty || $0 == ch.title ? nil : $0 }
        revision += 1
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
            guard !segments.isEmpty else {
                playWhenLoaded = loading
                return
            }
            playing = true
            if let live, liveKey == key(chapter, segment), live.currentTime > 0 {
                live.rate = speed
                live.play()  // carry on where the line was paused
            } else {
                playLiveLine()
            }
        }
        sampler?.stop()
        sampling = nil
        updateNowPlaying()
    }

    func pause() {
        let was = playing
        playing = false
        playWhenLoaded = false
        offline.pause()
        live?.pause()
        gapTask?.cancel()
        playTask?.cancel()
        loading = false
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

    /// Plays from a line of the page (tapped there).
    func play(from s: Int) {
        switch mode {
        case .offline:
            guard let t = timeline, t.chapters.indices.contains(chapter) else { return }
            seek(to: t.ms(chapter: t.chapters[chapter].chapter, segment: s))
            if !playing { play() }
        case .live:
            if !playing { live?.stop(); liveKey = "" }
            goToLine(s)
            if !playing { play() }
        }
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
            segment = max(0, t.lines[i].segment)
        }
        let c = t.chapterIndex(at: ms)
        if c != chapter {
            let ended = chapter >= 0 && c == chapter + 1 && playing
            chapter = c
            buildOfflinePage()
            updateNowPlaying()
            if ended && sleep == .endOfChapter {
                setSleep(.off)
                pause()
            }
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
                p.volume = Self.volume
                live = p
                liveKey = key(c, s)
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
                let stop = sleep == .endOfChapter
                if stop {
                    setSleep(.off)
                    pause()
                }
                do {
                    try await loadChapter(chapter + 1, at: 0)
                    saveLivePosition()
                    if !stop { playLiveLine() }
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
        liveKey = ""
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

    // MARK: - cast

    /// The narrator, then everyone with a voice, most lines first.
    var cast: [CastMember] {
        if let b = macBook {
            let colors = b.colors
            let narrator = CastMember(id: "", name: "Narrator", summary: "Reads everything that isn't said aloud", voice: b.narrator?.designed_from,
                                      sample: b.narrator?.voice.map { VoiceSample(voice: $0, rate: b.narrator?.rate ?? 180, pitchShift: b.narrator?.pitch_shift ?? 0) })
            return [narrator] + b.cast.sorted { ($0.lines ?? 0) > ($1.lines ?? 0) }.map { m in
                CastMember(id: m.id, name: m.name, color: colors[m.id], summary: m.summary, lines: m.lines, voice: m.designed_from,
                           sample: m.voice.map { VoiceSample(voice: $0, rate: m.rate ?? 180, pitchShift: m.pitch_shift ?? 0) })
            }
        }
        guard let t = timeline else { return [] }
        return [CastMember(id: "", name: "Narrator")] + t.speakers.sorted { $0.value < $1.value }.map {
            CastMember(id: $0.key, name: $0.value, color: t.colors?[$0.key])
        }
    }

    func name(of id: String?) -> String? {
        guard let id else { return nil }
        return macBook?.cast.first { $0.id == id }?.name ?? timeline?.speakers[id] ?? id
    }

    func color(of id: String?) -> String? {
        guard let id else { return nil }
        return macBook?.colors[id] ?? timeline?.colors?[id]
    }

    /// Changing who says a line needs the Mac.
    var canChangeSpeakers: Bool { library?.reachable == true && macBook != nil }

    /// Gives a quote (every line of it) to someone else on the Mac (nil: the narrator reads it).
    func setSpeaker(_ speaker: String?, segment s: Int) async {
        guard let id = bookID, let library else { return }
        let ci = mode == .offline ? (timeline.flatMap { $0.chapters.indices.contains(chapter) ? $0.chapters[chapter].chapter : nil } ?? chapter) : chapter
        do {
            let r = try await library.mac.setSpeaker(speaker, chapter: ci, segment: s, of: id)
            guard bookID == id else { return }
            macBook?.cast = r.cast
            switch mode {
            case .live:
                for i in r.changed where segments.indices.contains(i) { segments[i].speaker = speaker }
                for i in r.changed { lines[key(ci, i)] = nil }
                page = segments.map { PageLine(segment: $0.id, text: $0.text, para: $0.para, dialogue: $0.kind == "dialogue", q: $0.q, speaker: $0.speaker) }
                revision += 1
                showLiveLine()
                if playing && r.changed.contains(segment) { goToLine(segment) }  // say it again in the new voice
            case .offline:
                library.setSpeaker(speaker, chapter: ci, segments: r.changed, of: id)
                timeline = library.timeline(id)
                buildOfflinePage()
                current = nil
                updateOfflineLine()
                notice = "Changed on your Mac. This iPhone's offline copy keeps the old voice until you download an update; Live from Mac uses the new one."
            }
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func dismissNotice() { notice = nil }

    /// A character's voice, saying one of their lines from this chapter.
    func sample(_ member: CastMember) {
        guard let v = member.sample, let id = bookID, let library else { return }
        if sampling == member.id {
            sampler?.stop()
            sampling = nil
            return
        }
        pause()
        sampler?.stop()
        sampling = member.id
        let said = page.first { $0.dialogue && $0.speaker == member.id && $0.text.count > 25 }?.text ?? ""
        Task {
            do {
                let data = try await library.mac.sample(v, text: said)
                guard sampling == member.id, bookID == id else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(data: data)
                p.delegate = sampleDone
                p.volume = Self.volume
                sampler = p
                p.play()
            } catch {
                if sampling == member.id { sampling = nil }
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @ObservationIgnored private lazy var sampleDone: Finished = {
        let f = Finished()
        f.done = { [weak self] in self?.sampling = nil }
        return f
    }()

    // MARK: - sleep timer

    func setSleep(_ s: Sleep) {
        sleepTask?.cancel()
        sleep = s
        sleepEnds = nil
        guard case .minutes(let m) = s else { return }
        let ends = Date().addingTimeInterval(TimeInterval(m * 60))
        sleepEnds = ends
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(ends.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            pause()
            sleep = .off
            sleepEnds = nil
        }
    }

    #if DEBUG
    /// Where playback is, for the simulator's test scripts.
    var debugState: String {
        let at = mode == .live ? (live?.currentTime ?? -1) : Double(ms) / 1000
        return "mode=\(mode.rawValue) playing=\(playing) chapter=\(chapter) segment=\(segment) line=\(liveKey) at=\(String(format: "%.2f", at))"
    }
    #endif

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
