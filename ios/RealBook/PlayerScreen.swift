import SwiftUI
import UIKit

/// A book playing, full screen: only its cover, or (Text) only the whole chapter, laid out as on the
/// Mac. The controls below are the same for both.
struct PlayerScreen: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Look.self) private var look
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bookID: String
    let close: () -> Void
    @AppStorage("showText") private var showText = false
    @State private var scrubbing: Double?
    @State private var cover: UIImage?
    @State private var following = true
    @State private var followAgain: Task<Void, Never>?
    @State private var sheet: Sheet?
    @State private var showSaved = false
    @State private var dragY: CGFloat = 0
    @State private var height: CGFloat = 800
    @State private var waiting = false
    @State private var panelHeight: CGFloat = 120

    enum Sheet: Identifiable {
        case chapters, look, cast, who(Int)
        var id: String {
            switch self {
            case .chapters: "chapters"
            case .look: "look"
            case .cast: "cast"
            case .who(let s): "who\(s)"
            }
        }
    }

    /// The cover view is always dark; the text takes the Aa menu's theme.
    private var scheme: ColorScheme { showText ? (look.scheme ?? systemScheme) : .dark }
    private var ink: Color { showText ? Color(look.current.ink) : .white }
    private var muted: Color { showText ? Color(look.current.muted) : .white.opacity(0.6) }

    var body: some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 18).padding(.top, 8)
                .contentShape(Rectangle())
                .gesture(closeDrag)
            // The controls float on glass: the text runs on under them, and the cover stops above them.
            ZStack(alignment: .bottom) {
                if showText {
                    page.ignoresSafeArea(edges: .bottom)
                } else {
                    coverView.padding(.horizontal, 22).padding(.bottom, panelHeight + 8)
                        .contentShape(Rectangle())
                        .gesture(closeDrag)
                }
                if showText {
                    // The text fades on its way under the glass, so only a hint of it shows through.
                    LinearGradient(stops: [.init(color: Color(look.current.background).opacity(0), location: 0),
                                           .init(color: Color(look.current.background).opacity(0.82), location: 60 / (panelHeight + 60)),
                                           .init(color: Color(look.current.background).opacity(0.97), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: panelHeight + 60)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                    if !following {
                        Button { following = true } label: {
                            Label("Line Being Read", systemImage: "text.line.first.and.arrowtriangle.forward")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glass(in: Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .padding(.bottom, panelHeight + 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                VStack(spacing: 10) {
                    if let message = player.notice ?? player.problem {
                        Banner(text: message) { player.dismissNotice() }
                    }
                    VStack(spacing: 4) {
                        scrubber
                        controls
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, now in panelHeight = now } })
            }
            .animation(.easeOut(duration: 0.2), value: following)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Solid underneath, so the library doesn't show through while the page and the cover fade
            // into each other; it's only seen while the player is dragged down to close.
            ZStack {
                Color.black.clipShape(dragShape).ignoresSafeArea().opacity(dragY > 0 ? 0 : 1)
                background
            }
        }
        .foregroundStyle(ink)
        .tint(ink)
        .environment(\.colorScheme, scheme)
        .offset(y: dragY)
        .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height } })
        .animation(.easeInOut(duration: 0.25), value: showText)
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .chapters: ChapterList { sheet = nil }.presentationDetents([.medium, .large])
                case .look: AppearanceSheet().presentationDetents([.height(380)])
                case .cast: CastSheet().presentationDetents([.medium, .large])
                case .who(let s): SpeakerPicker(segment: s) { sheet = nil }.presentationDetents([.medium, .large])
                }
            }
            .environment(\.colorScheme, systemScheme)
            // Black in dark mode, as everywhere else in the app.
            .presentationBackground(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white }))
        }
        .onAppear { player.open(bookID, library: library) }
        .task(id: bookID) { cover = await library.cover(bookID) }
        .onChange(of: player.playing) { _, now in if now { following = true } }
        .onChange(of: following) { _, now in if now { followAgain?.cancel() } }
        #if DEBUG
        .task { await debugScript() }
        #endif
    }

    @ViewBuilder private var background: some View {
        if showText {
            Color(look.current.background).clipShape(dragShape).ignoresSafeArea()
        } else {
            // The cover, blurred, behind everything. In an overlay, so its size doesn't widen the page.
            Color.black
                .overlay {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                            .blur(radius: 60).saturation(1.3).opacity(0.55)
                    }
                }
                .overlay(LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.7), .black], startPoint: .top, endPoint: .bottom))
                .clipShape(dragShape)
                .ignoresSafeArea()
        }
    }

    // MARK: - swipe down to close

    /// Only the background is rounded: a mask over the whole screen made every press and update slow to draw.
    private var dragShape: RoundedRectangle { RoundedRectangle(cornerRadius: dragY > 0 ? 28 : 0, style: .continuous) }

    private static let dragStart: CGFloat = 10  // moved this far before it counts as a drag

    /// Follows the finger down. Measured on the screen, since the view moves with the finger.
    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: Self.dragStart, coordinateSpace: .global)
            .onChanged { v in
                let y = v.translation.height - Self.dragStart
                dragY = y >= 0 ? y : y * height * 0.55 / (height + 0.55 * abs(y))  // upwards it resists: there's nothing there
            }
            .onEnded { v in finishDrag(velocity: v.velocity.height) }
    }

    /// Closes if the flick would carry it past half way (the way a scroll view coasts), else goes back,
    /// in both cases carrying on at the finger's speed.
    private func finishDrag(velocity: CGFloat) {
        let coast = velocity / 1000 * 0.998 / (1 - 0.998)
        let closing = dragY + coast > height / 2
        let target = closing ? height + 60 : 0
        let distance = target - dragY
        let spring = Animation.interpolatingSpring(duration: 0.32, bounce: closing || reduceMotion ? 0 : 0.15,
                                                   initialVelocity: abs(distance) > 1 ? Double(velocity / distance) : 0)
        withAnimation(spring, completionCriteria: .logicallyComplete) {
            dragY = target
        } completion: {
            guard closing else { return }
            var quietly = Transaction()
            quietly.disablesAnimations = true  // it's already off the screen
            withTransaction(quietly) { close() }
        }
    }

    // MARK: - top

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36).glass(in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            modeSwitch
            Spacer()
            Menu {
                Button("Read This Line Again", systemImage: "arrow.counterclockwise") { Task { await player.readAgain() } }
                    .disabled(!player.canChangeSpeakers)
                if player.mode == .live {
                    Button("Offline Listening", systemImage: "iphone") { showSaved = true }
                }
                if player.mode == .offline {
                    Button("Previous Line", systemImage: "backward.end") { player.previousLine() }
                    Button("Next Line", systemImage: "forward.end") { player.nextLine() }
                }
                Divider()
                Button("Cast", systemImage: "person.2") { sheet = .cast }
                Button("Text Size & Theme", systemImage: "textformat.size") { sheet = .look }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36).glass(in: Circle())
            }
            .accessibilityLabel("More")
        }
        .buttonStyle(PressStyle())
    }

    /// Offline copy or live from the Mac, when both are possible.
    @ViewBuilder private var modeSwitch: some View {
        let canLive = library.reachable && library.remoteBook(bookID) != nil
        if player.hasOfflineCopy && canLive {
            Picker("Listen from", selection: Binding(get: { player.mode }, set: { player.switchTo($0) })) {
                Text("Offline copy").tag(Player.Mode.offline)
                Text("Live from Mac").tag(Player.Mode.live)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
        } else {
            let away = player.mode == .live && !library.reachable
            // What's saved shows here, and tapping it says more.
            Button { showSaved = true } label: {
                Label(modeLabel(away: away), systemImage: away ? "iphone" : player.mode == .live ? "dot.radiowaves.left.and.right" : "arrow.down.circle")
                    .font(.caption.weight(.semibold)).textCase(.uppercase)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glass(in: Capsule())
            }
            .disabled(player.mode != .live)
            .popover(isPresented: $showSaved) {
                OfflineTime().presentationCompactAdaptation(.popover)
            }
        }
    }

    private func modeLabel(away: Bool) -> String {
        guard player.mode == .live else { return "Offline copy" }
        guard let minutes = player.savedMinutes, minutes > 0 else { return away ? "Saved on this iPhone" : "Live from your Mac" }
        return away ? "\(Kept.duration(minutes: minutes)) left offline" : "Live · \(Kept.duration(minutes: minutes)) saved"
    }

    // MARK: - middle

    /// Only the cover, as big as it fits, at its own shape. Tapping it shows the text.
    private var coverView: some View {
        VStack(spacing: 0) {
            CoverImage(image: cover, title: player.title, radius: 10)
                .aspectRatio(cover.map { $0.size.width / max(1, $0.size.height) } ?? 2 / 3, contentMode: .fit)
                .shadow(color: .black.opacity(0.55), radius: 22, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { showText = true }
                .padding(.top, 16)
            VStack(spacing: 3) {
                Text(player.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                if !player.chapterLabel.isEmpty {
                    Text(player.chapterLabel).font(.subheadline).foregroundStyle(muted).lineLimit(1)
                }
            }
            .padding(.vertical, 16)
        }
    }

    /// The whole chapter, as on the Mac: tap a line to play from it, hold it for more.
    @ViewBuilder private var page: some View {
        if player.bookID == bookID && !player.page.isEmpty {
            ChapterPage(
                key: "\(bookID):\(player.mode.rawValue):\(player.chapter)", revision: player.revision, lines: player.page,
                title: player.pageTitle, section: player.pageSection, current: player.segment, follow: following,
                look: look, scheme: scheme, hasNext: player.chapter + 1 < player.chapterTitles.count, bottomInset: panelHeight + 56,
                name: { player.name(of: $0) }, color: { player.color(of: $0) },
                onTap: { s in
                    following = true
                    player.play(from: s)
                },
                onWho: { s in if player.canChangeSpeakers { sheet = .who(s) } },
                onNext: {
                    following = true
                    player.goTo(chapter: player.chapter + 1)
                },
                onScrolledAway: {
                    following = false
                    // Carry on following a little after the scrolling stops, if the book is playing.
                    followAgain?.cancel()
                    followAgain = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(8))
                            if !Task.isCancelled && player.playing {
                                following = true
                                return
                            }
                        }
                    }
                },
                menu: menu
            )
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color(look.current.background), Color(look.current.background).opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16).allowsHitTesting(false)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func menu(_ s: Int) -> UIMenu? {
        guard let line = player.page.first(where: { $0.segment == s }) else { return nil }
        var items: [UIMenuElement] = [
            UIAction(title: "Play from Here", image: UIImage(systemName: "play")) { _ in
                following = true
                player.play(from: s)
            },
        ]
        items.append(UIAction(title: "Read This Line Again", subtitle: player.canChangeSpeakers ? nil : "When your Mac is near",
                              image: UIImage(systemName: "arrow.counterclockwise"), attributes: player.canChangeSpeakers ? [] : .disabled) { _ in
            following = true
            Task { await player.readAgain(segment: s) }
        })
        if line.dialogue {
            let who = player.name(of: line.speaker) ?? "Unknown speaker"
            if player.canChangeSpeakers {
                items.append(UIAction(title: "Who Says This?", subtitle: who, image: UIImage(systemName: "person.crop.circle.badge.questionmark")) { _ in
                    sheet = .who(s)
                })
            } else {
                items.append(UIAction(title: who, subtitle: "Change who says it when your Mac is near", image: UIImage(systemName: "person"),
                                      attributes: .disabled) { _ in })
            }
        }
        items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = line.text })
        return UIMenu(children: items)
    }

    // MARK: - controls

    private var scrubber: some View {
        let labels = player.progressLabels(at: scrubbing)
        return VStack(spacing: 0) {
            Slider(value: Binding(get: { scrubbing ?? player.progress }, set: { scrubbing = $0 }), in: 0...1) { editing in
                if !editing, let s = scrubbing {
                    player.scrub(to: s)
                    scrubbing = nil
                }
            }
            HStack {
                Text(labels.0)
                Spacer()
                Text(labels.1)
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(muted)
        }
    }

    /// One row, as on the Mac: speed and sleep, play in the middle, then the text and chapters. The
    /// offline copy skips by time here; its line by line is in the top bar's menu.
    private var controls: some View {
        let offline = player.mode == .offline
        return HStack(spacing: 0) {
            Menu {
                Picker("Speed", selection: Bindable(player).speed) {
                    ForEach(Player.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
            } label: {
                item { Text(Self.speedLabel(player.speed)).font(.system(size: 14, weight: .semibold).monospacedDigit()) }
            }
            .accessibilityLabel("Speed")
            Menu {
                Picker("Sleep Timer", selection: Binding(get: { player.sleep }, set: { player.setSleep($0) })) {
                    Text("Off").tag(Player.Sleep.off)
                    ForEach([5, 15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag(Player.Sleep.minutes($0)) }
                    Text("End of Chapter").tag(Player.Sleep.endOfChapter)
                }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    item(on: player.sleep != .off) {
                        if let ends = player.sleepEnds {
                            Text(Player.time(Int(max(0, ends.timeIntervalSinceNow) * 1000))).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        } else {
                            Image(systemName: player.sleep == .off ? "moon.zzz" : "moon.fill")
                        }
                    }
                }
            }
            .accessibilityLabel(sleepLabel)
            Spacer(minLength: 0)
            control(offline ? "gobackward.15" : "backward.end.fill", offline ? "Back 15 seconds" : "Previous line") {
                if offline { player.skip(seconds: -15) } else { player.previousLine() }
            }
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(ink).frame(width: 50, height: 50)
                    if waiting && player.loading && player.playing {
                        ProgressView().tint(showText ? Color(look.current.background) : .black)
                    } else {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(showText ? Color(look.current.background) : .black)
                            .offset(x: player.playing ? 0 : 1.5)
                            // Play and pause swap at once: animated with the button letting go, the
                            // new icon faded and slid in, which felt slow to answer.
                            .contentTransition(.identity)
                            .transaction { $0.animation = nil }
                    }
                }
            }
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            .task(id: player.loading && player.playing) {  // the spinner only if it takes a while: not a flash on every press
                waiting = false
                guard player.loading && player.playing else { return }
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { waiting = true }
            }
            control(offline ? "goforward.30" : "forward.end.fill", offline ? "Forward 30 seconds" : "Next line") {
                if offline { player.skip(seconds: 30) } else { player.nextLine() }
            }
            Spacer(minLength: 0)
            Button { showText.toggle() } label: {
                item(on: showText) { Image(systemName: "text.quote") }
            }
            .accessibilityLabel("Text")
            Button { sheet = .chapters } label: {
                item { Image(systemName: "list.bullet") }
            }
            .accessibilityLabel("Chapters")
        }
        .buttonStyle(PressStyle())
    }

    private func control(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 19)).frame(width: 44, height: 44) }
            .accessibilityLabel(label)
    }

    private var sleepLabel: String {
        if let ends = player.sleepEnds { return Player.time(Int(max(0, ends.timeIntervalSinceNow) * 1000)) }
        return player.sleep == .endOfChapter ? "Chapter end" : "Sleep"
    }

    private func item(on: Bool = false, @ViewBuilder icon: () -> some View) -> some View {
        icon()
            .font(.system(size: 16, weight: .medium))
            .frame(width: 40, height: 40)
            .background(on ? ink.opacity(0.16) : .clear, in: Circle())
            .contentShape(Rectangle())
    }

    static func speedLabel(_ s: Float) -> String { s == 1 ? "1×" : String(format: "%g×", s) }

    #if DEBUG
    /// For trying the screen in the simulator: `-view text`, `-sheet cast|look|chapters|who`, and
    /// `-script "play,wait 5,pause,..."` (also `prev`, `sleep chapter`), which presses the buttons and prints where playback is.
    private func debugScript() async {
        if let v = UserDefaults.standard.string(forKey: "view") { showText = v == "text" }
        try? await Task.sleep(for: .seconds(3))
        switch UserDefaults.standard.string(forKey: "sheet") {
        case "cast": sheet = .cast
        case "look": sheet = .look
        case "chapters": sheet = .chapters
        case "who": sheet = .who(player.page.first { $0.dialogue }?.segment ?? 0)
        case "saved": showSaved = true
        default: break
        }
        for step in (UserDefaults.standard.string(forKey: "script") ?? "").split(separator: ",").map({ $0.split(separator: " ") }) {
            switch step.first {
            case "play": player.play()
            case "pause": player.pause()
            case "next": player.nextLine()
            case "prev": player.previousLine()
            case "sleep": player.setSleep(step[1] == "chapter" ? .endOfChapter : .minutes(Int(step[1]) ?? 0))
            case "tap": player.play(from: Int(step[1]) ?? 0)
            case "chapter": player.goTo(chapter: Int(step[1]) ?? 0)
            case "wait": try? await Task.sleep(for: .seconds(Double(step[1]) ?? 1))
            case "away": following = false
            case "show": showText = step[1] == "text"
            case "drag": dragY = CGFloat(Double(step[1]) ?? 0)
            case "release": finishDrag(velocity: CGFloat(Double(step[1]) ?? 0))
            case "again": await player.readAgain(segment: Int(step[1]) ?? 0)
            case "who": await player.setSpeaker(step[2] == "-" ? nil : String(step[2]), segment: Int(step[1]) ?? 0)
            default: break
            }
            print("[script] \(step.joined(separator: " ")): \(player.debugState)")
        }
    }
    #endif
}

struct ChapterList: View {
    @Environment(Player.self) private var player
    let close: () -> Void

    /// Chapters in a row from one part of the book. The heading goes to the part's first chapter,
    /// and stands in for it when they share a name.
    private struct Part: Identifiable {
        var first: Int
        var heading: String?
        var rows: [Int]
        var id: Int { first }
    }

    private var parts: [Part] {
        var parts: [Part] = []
        for i in player.chapterTitles.indices {
            let section = player.chapterSections.indices.contains(i) ? player.chapterSections[i] : ""
            if !section.isEmpty, parts.last?.heading == section {
                parts[parts.count - 1].rows.append(i)
            } else {
                parts.append(Part(first: i, heading: section.isEmpty ? nil : section, rows: [i]))
            }
        }
        return parts.map { part in
            guard let heading = part.heading, player.chapterTitles[part.first] == heading else { return part }
            if part.rows.count == 1 { return Part(first: part.first, heading: nil, rows: part.rows) }  // a part that's one chapter
            return Part(first: part.first, heading: heading, rows: Array(part.rows.dropFirst()))
        }
    }

    private func go(to chapter: Int) {
        player.goTo(chapter: chapter)
        close()
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                let parts = parts
                List {
                    ForEach(parts) { part in
                        Section {
                            ForEach(part.rows, id: \.self) { i in
                                Button {
                                    go(to: i)
                                } label: {
                                    HStack {
                                        Text(player.chapterTitles[i]).foregroundStyle(.primary)
                                        Spacer()
                                        if i == player.chapter { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary) }
                                    }
                                    .padding(.leading, part.heading == nil ? 0 : 14)
                                }
                                .id(i)
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            if let heading = part.heading {
                                Button {
                                    go(to: part.first)
                                } label: {
                                    HStack {
                                        Text(heading).font(.subheadline.bold()).foregroundStyle(.primary).textCase(nil)
                                        Spacer()
                                        if part.first == player.chapter && !part.rows.contains(part.first) {
                                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(.regularMaterial)  // the chapters scroll under it
                                }
                                .listRowInsets(EdgeInsets())
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    // A chapter shown as its part's heading has no row of its own: go to the row after it.
                    let part = parts.last { $0.first <= player.chapter }
                    let target = part?.rows.contains(player.chapter) == true ? player.chapter : part?.rows.first
                    if let target { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", action: close) }
        }
    }
}

/// A press shows at once and lets go quickly. (The plain style's slow fade looks odd on the big play button.)
private struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.6 : 1)
            .animation(configuration.isPressed ? nil : .spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}
