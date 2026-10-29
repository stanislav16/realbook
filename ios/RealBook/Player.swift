import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays a book's offline copy: in the background, from the lock screen, at any speed.
@MainActor
@Observable
final class Player {
    private(set) var bookID: String?
    private(set) var timeline: Timeline?
    private(set) var playing = false
    private(set) var ms = 0
    private(set) var line: Timeline.Line?
    private(set) var chapter = 0
    var speed: Float = UserDefaults.standard.object(forKey: "speed") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "speed")
            if playing { player.rate = speed }
            updateNowPlaying()
        }
    }

    static let speeds: [Float] = [0.8, 1, 1.15, 1.3, 1.5, 1.75, 2]

    private let player = AVPlayer()
    private var observer: Any?
    private var library: Library?
    private var lastSaved = Date.distantPast
    private var artwork: MPMediaItemArtwork?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        player.automaticallyWaitsToMinimizeStalling = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated { if type == .began { self?.pause() } }
        }
        setUpRemoteCommands()
    }

    var durationMs: Int { timeline?.ms ?? 0 }

    func open(_ book: LocalBook, library: Library) {
        self.library = library
        guard bookID != book.id else { return }
        pause()
        bookID = book.id
        timeline = library.timeline(book.id)
        player.replaceCurrentItem(with: AVPlayerItem(url: Library.audio(of: book.id)))
        player.currentItem?.audioTimePitchAlgorithm = .timeDomain
        artwork = UIImage(contentsOfFile: Library.cover(of: book.id).path).map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        seek(to: book.positionMs, save: false)
    }

    /// The book's position moved on the Mac: follow it, unless it's playing here.
    func follow(_ book: LocalBook) {
        guard book.id == bookID, !playing else { return }
        seek(to: book.positionMs, save: false)
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: speed)
        playing = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        let was = playing
        playing = false
        savePosition()
        updateNowPlaying()
        if was, let library { Task { await library.sync() } }
    }

    func seek(to target: Int, save: Bool = true) {
        let clamped = max(0, min(target, max(0, durationMs - 500)))
        ms = clamped
        updateLine()
        player.seek(to: CMTime(value: CMTimeValue(clamped), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        if save { savePosition() }
        updateNowPlaying()
    }

    func skip(seconds: Int) { seek(to: ms + seconds * 1000) }

    /// Back to the start of the line before (or of this one, if it only just started).
    func previousLine() {
        guard let t = timeline, !t.lines.isEmpty else { return }
        let i = t.lineIndex(at: ms)
        let target = ms - t.lines[i].ms > 1500 ? i : max(0, i - 1)
        seek(to: t.lines[target].ms)
    }

    func nextLine() {
        guard let t = timeline, !t.lines.isEmpty else { return }
        let i = t.lineIndex(at: ms)
        if i + 1 < t.lines.count { seek(to: t.lines[i + 1].ms) }
    }

    func goTo(chapter i: Int) {
        guard let t = timeline, t.chapters.indices.contains(i) else { return }
        seek(to: t.chapters[i].ms)
    }

    private func tick(_ time: CMTime) {
        guard playing, time.isNumeric else { return }
        ms = Int(time.seconds * 1000)
        updateLine()
        if Date().timeIntervalSince(lastSaved) > 5 { savePosition() }
    }

    private func updateLine() {
        guard let t = timeline, !t.lines.isEmpty else { return }
        let l = t.lines[t.lineIndex(at: ms)]
        if line?.ms != l.ms { line = l }
        let c = t.chapterIndex(at: ms)
        if c != chapter {
            chapter = c
            updateNowPlaying()
        }
    }

    private func savePosition() {
        guard let bookID else { return }
        lastSaved = Date()
        library?.setPosition(ms, of: bookID)
    }

    func speakerName(_ line: Timeline.Line) -> String? {
        guard let id = line.speaker else { return nil }
        return timeline?.speakers[id] ?? id
    }

    // MARK: - lock screen

    private func updateNowPlaying() {
        guard let t = timeline else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.chapters.indices.contains(chapter) ? t.chapters[chapter].title : t.title,
            MPMediaItemPropertyAlbumTitle: t.title,
            MPMediaItemPropertyArtist: t.author,
            MPMediaItemPropertyPlaybackDuration: Double(t.ms) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(ms) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
