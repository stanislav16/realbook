import SwiftUI
import UIKit

/// A book playing, full screen: its cover and the line being read, or (Text) the whole chapter laid
/// out as on the Mac. The controls below are the same for both.
struct PlayerScreen: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Look.self) private var look
    @Environment(\.colorScheme) private var systemScheme
    let bookID: String
    let close: () -> Void
    @AppStorage("showText") private var showText = false
    @State private var scrubbing: Double?
    @State private var cover: UIImage?
    @State private var following = true
    @State private var sheet: Sheet?

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
            if showText {
                page
            } else {
                coverView.padding(.horizontal, 22)
            }
            VStack(spacing: 0) {
                if let message = player.notice ?? player.problem {
                    Banner(text: message) { player.dismissNotice() }.padding(.bottom, 10)
                }
                scrubber
                controls.padding(.top, 10).padding(.bottom, 14)
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, showText ? 10 : 0)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .foregroundStyle(ink)
        .tint(ink)
        .environment(\.colorScheme, scheme)
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
        }
        .onAppear { player.open(bookID, library: library) }
        .task(id: bookID) { cover = await library.cover(bookID) }
        .onChange(of: player.playing) { _, now in if now { following = true } }
        #if DEBUG
        .task { await debugScript() }
        #endif
    }

    @ViewBuilder private var background: some View {
        if showText {
            Color(look.current.background).ignoresSafeArea()
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
                .clipped()
                .ignoresSafeArea()
        }
    }

    // MARK: - top

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36).background(ink.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            modeSwitch
            Spacer()
            Menu {
                Button("Cast", systemImage: "person.2") { sheet = .cast }
                Button("Text Size & Theme", systemImage: "textformat.size") { sheet = .look }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36).background(ink.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
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
            Label(player.mode == .live ? "Live from your Mac" : "Offline copy",
                  systemImage: player.mode == .live ? "dot.radiowaves.left.and.right" : "arrow.down.circle")
                .font(.caption.weight(.semibold)).textCase(.uppercase)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(ink.opacity(0.12), in: Capsule())
        }
    }

    // MARK: - middle

    private var coverView: some View {
        VStack(spacing: 0) {
            CoverImage(image: cover, title: player.title)
                .frame(width: 150, height: 225)
                .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                .padding(.top, 22)
            VStack(spacing: 3) {
                Text(player.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                if player.chapterTitles.indices.contains(player.chapter) {
                    Text(player.chapterTitles[player.chapter]).font(.subheadline).foregroundStyle(muted).lineLimit(1)
                }
            }
            .padding(.top, 14)
            lines
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { showText = true }  // the whole chapter, as with lyrics
        }
    }

    /// The line being read, between the lines before and after it.
    private var lines: some View {
        VStack(spacing: 12) {
            if let before = player.before {
                Text(before.text).font(.system(.subheadline, design: .serif)).foregroundStyle(.white.opacity(0.32))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            if let line = player.current {
                VStack(spacing: 8) {
                    if let who = line.speaker {
                        Text(who.uppercased()).font(.caption2.weight(.bold)).tracking(0.8)
                            .foregroundStyle(Color(speaker: line.color) ?? .white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background((Color(speaker: line.color) ?? .white).opacity(0.18), in: Capsule())
                    }
                    Text(line.speaker == nil ? line.text : "“\(line.text)”")
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(7)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: line)
                }
            } else if player.loading {
                ProgressView().tint(.white)
            }
            if let after = player.after {
                Text(after.text).font(.system(.subheadline, design: .serif)).foregroundStyle(.white.opacity(0.32))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 12)
    }

    /// The whole chapter, as on the Mac: tap a line to play from it, hold it for more.
    @ViewBuilder private var page: some View {
        if player.bookID == bookID && !player.page.isEmpty {
            ChapterPage(
                key: "\(bookID):\(player.mode.rawValue):\(player.chapter)", revision: player.revision, lines: player.page,
                title: player.pageTitle, section: player.pageSection, current: player.segment, follow: following,
                look: look, scheme: scheme, hasNext: player.chapter + 1 < player.chapterTitles.count, bottomInset: 0,
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
                onScrolledAway: { following = false },
                menu: menu
            )
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.035),
                                         .init(color: .black, location: 0.965), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) {
                if !following {
                    Button { following = true } label: {
                        Label("Line Being Read", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: following)
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
        return VStack(spacing: 4) {
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
            .font(.caption.monospacedDigit()).foregroundStyle(muted)
        }
    }

    /// Centred on the play button, the same distance between each.
    private var controls: some View {
        HStack(spacing: player.mode == .offline ? 22 : 40) {
            control("backward.end.fill", "Previous line") { player.previousLine() }
            if player.mode == .offline { control("gobackward.15", "Back 15 seconds") { player.skip(seconds: -15) } }
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(ink).frame(width: 68, height: 68)
                    if player.loading && player.playing {
                        ProgressView().tint(showText ? Color(look.current.background) : .black)
                    } else {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(showText ? Color(look.current.background) : .black)
                            .offset(x: player.playing ? 0 : 2)
                    }
                }
            }
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            if player.mode == .offline { control("goforward.30", "Forward 30 seconds") { player.skip(seconds: 30) } }
            control("forward.end.fill", "Next line") { player.nextLine() }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func control(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title2).frame(width: 48, height: 48) }
            .accessibilityLabel(label)
    }

    /// Four equal places: speed, sleep timer, the text, and chapters.
    private var footer: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("Speed", selection: Bindable(player).speed) {
                    ForEach(Player.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
            } label: {
                item(label: "Speed") { Text(Self.speedLabel(player.speed)).font(.system(size: 17, weight: .semibold)) }
            }
            Menu {
                Picker("Sleep Timer", selection: Binding(get: { player.sleep }, set: { player.setSleep($0) })) {
                    Text("Off").tag(Player.Sleep.off)
                    ForEach([5, 15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag(Player.Sleep.minutes($0)) }
                    Text("End of Chapter").tag(Player.Sleep.endOfChapter)
                }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    item(on: player.sleep != .off, label: sleepLabel) { Image(systemName: player.sleep == .off ? "moon.zzz" : "moon.fill") }
                }
            }
            Button { showText.toggle() } label: {
                item(on: showText, label: "Text") { Image(systemName: "text.quote") }
            }
            Button { sheet = .chapters } label: {
                item(label: "Chapters") { Image(systemName: "list.bullet") }
            }
        }
        .buttonStyle(.plain)
    }

    private var sleepLabel: String {
        if let ends = player.sleepEnds { return Player.time(Int(max(0, ends.timeIntervalSinceNow) * 1000)) }
        return player.sleep == .endOfChapter ? "Chapter end" : "Sleep"
    }

    private func item(on: Bool = false, label: String, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 3) {
            icon()
                .font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 32)
                .background(on ? ink.opacity(0.16) : .clear, in: Capsule())
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    static func speedLabel(_ s: Float) -> String { s == 1 ? "1×" : String(format: "%g×", s) }

    #if DEBUG
    /// For trying the screen in the simulator: `-view text`, `-sheet cast|look|chapters|who`, and
    /// `-script "play,wait 5,pause,..."`, which presses the buttons and prints where playback is.
    private func debugScript() async {
        if let v = UserDefaults.standard.string(forKey: "view") { showText = v == "text" }
        try? await Task.sleep(for: .seconds(3))
        switch UserDefaults.standard.string(forKey: "sheet") {
        case "cast": sheet = .cast
        case "look": sheet = .look
        case "chapters": sheet = .chapters
        case "who": sheet = .who(player.page.first { $0.dialogue }?.segment ?? 0)
        default: break
        }
        for step in (UserDefaults.standard.string(forKey: "script") ?? "").split(separator: ",").map({ $0.split(separator: " ") }) {
            switch step.first {
            case "play": player.play()
            case "pause": player.pause()
            case "next": player.nextLine()
            case "tap": player.play(from: Int(step[1]) ?? 0)
            case "chapter": player.goTo(chapter: Int(step[1]) ?? 0)
            case "wait": try? await Task.sleep(for: .seconds(Double(step[1]) ?? 1))
            case "away": following = false
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

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.chapterTitles.enumerated()), id: \.offset) { i, title in
                        Button {
                            player.goTo(chapter: i)
                            close()
                        } label: {
                            HStack {
                                Text(title).foregroundStyle(.primary)
                                Spacer()
                                if i == player.chapter { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary) }
                            }
                        }
                        .id(i)
                    }
                }
                .onAppear { proxy.scrollTo(player.chapter, anchor: .center) }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", action: close) }
        }
    }
}

extension Color {
    /// A speaker's colour ("#rrggbb" from the Mac) on a dark page: mixed with white, 72 to 28, as the
    /// Mac does on its dark pages, so the darker ones stay readable.
    init?(speaker hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        let mix = { (c: Int) in (Double(c & 0xff) / 255) * 0.72 + 0.28 }
        self.init(red: mix(v >> 16), green: mix(v >> 8), blue: mix(v))
    }
}
