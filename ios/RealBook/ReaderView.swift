import SwiftUI
import UIKit

/// A book as the Mac shows it: the chapter's text with the line being read highlighted, the player
/// along the bottom, and Contents, Aa and Cast at the top. The player opens into Now Playing.
struct ReaderView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Look.self) private var look
    @Environment(\.colorScheme) private var scheme
    let bookID: String
    @State private var following = true
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case contents, look, cast, nowPlaying, who(Int)
        var id: String {
            switch self {
            case .contents: "contents"
            case .look: "look"
            case .cast: "cast"
            case .nowPlaying: "now"
            case .who(let s): "who\(s)"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(look.current.background).ignoresSafeArea()
            if player.bookID == bookID && !player.page.isEmpty {
                ChapterPage(
                    key: "\(bookID):\(player.mode.rawValue):\(player.chapter)", revision: player.revision, lines: player.page,
                    title: player.pageTitle, section: player.pageSection, current: player.segment, follow: following,
                    look: look, scheme: scheme, hasNext: player.chapter + 1 < player.chapterTitles.count, bottomInset: 84,
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
                .ignoresSafeArea(edges: .bottom)
            } else if let problem = player.problem {
                ContentUnavailableView("Can't open this book", systemImage: "wifi.exclamationmark", description: Text(problem))
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
            VStack(spacing: 8) {
                if !following && !player.page.isEmpty {
                    Button {
                        following = true
                    } label: {
                        Label("Line Being Read", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let message = player.notice ?? (player.page.isEmpty ? nil : player.problem) {
                    Banner(text: message) { player.dismissNotice() }
                }
                ReaderBar { sheet = .nowPlaying }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.2), value: following)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(player.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { sheet = .contents } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Contents")
                Button { sheet = .look } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Appearance")
                Button { sheet = .cast } label: { Image(systemName: "person.2") }
                    .accessibilityLabel("Cast")
            }
        }
        .toolbarBackground(Color(look.current.background), for: .navigationBar)
        .preferredColorScheme(look.scheme)
        .sheet(item: $sheet) { which in
            switch which {
            case .contents:
                ChapterList { sheet = nil }
                    .presentationDetents([.medium, .large])
            case .look:
                AppearanceSheet()
                    .presentationDetents([.height(380)])
            case .cast:
                CastSheet()
                    .presentationDetents([.medium, .large])
            case .nowPlaying:
                NowPlayingView(bookID: bookID) { sheet = nil }
            case .who(let s):
                SpeakerPicker(segment: s) { sheet = nil }
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear { player.open(bookID, library: library) }
        .onChange(of: player.playing) { _, now in if now { following = true } }
        #if DEBUG
        .task {
            // For trying screens in the simulator: `-sheet now|cast|look|contents`, `-scrollAway YES`.
            try? await Task.sleep(for: .seconds(3))
            switch UserDefaults.standard.string(forKey: "sheet") {
            case "now": sheet = .nowPlaying
            case "cast": sheet = .cast
            case "look": sheet = .look
            case "contents": sheet = .contents
            case "who": sheet = .who(player.page.first { $0.dialogue }?.segment ?? 0)
            default: break
            }
            if UserDefaults.standard.bool(forKey: "scrollAway") { following = false }
            // `-script "play,wait 5,pause,..."`: presses the buttons, printing where playback is after each step.
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
}

/// The player along the bottom of the page, as on the Mac: who's speaking, the chapter, and the
/// controls. Tapping it opens Now Playing.
struct ReaderBar: View {
    @Environment(Player.self) private var player
    @Environment(Look.self) private var look
    let open: () -> Void

    var body: some View {
        let ink = Color(look.current.ink)
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if let id = player.bookID {
                        BookCover(id: id, title: player.title).frame(width: 30, height: 45)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(speakerColor ?? Color(look.current.muted)).frame(width: 8, height: 8)
                            Text(player.current?.speaker ?? "Narrator").font(.subheadline.weight(.semibold))
                                .foregroundStyle(speakerColor ?? ink).lineLimit(1)
                        }
                        if player.chapterTitles.indices.contains(player.chapter) {
                            Text(player.chapterTitles[player.chapter]).font(.caption).foregroundStyle(Color(look.current.muted)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { player.previousLine() } label: { Image(systemName: "backward.end.fill").frame(width: 36, height: 44) }
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(ink).frame(width: 42, height: 42)
                    if player.loading && player.playing {
                        ProgressView().tint(Color(look.current.background))
                    } else {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(look.current.background))
                            .offset(x: player.playing ? 0 : 1.5)
                    }
                }
            }
            Button { player.nextLine() } label: { Image(systemName: "forward.end.fill").frame(width: 36, height: 44) }
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(ink)
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 62)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule().fill(ink.opacity(0.45)).frame(width: max(0, g.size.width * player.progress), height: 2.5)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 16).padding(.bottom, 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ink.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }

    private var speakerColor: Color? {
        player.current?.color.map { Color(UIColor(hex: $0).mixed(0.8, with: look.current.ink)) }
    }
}

struct Banner: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)) }.buttonStyle(.plain)
        }
        .font(.footnote)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The Mac's Aa menu: text size, theme, font, justification and coloured dialogue.
struct AppearanceSheet: View {
    @Environment(Look.self) private var look

    var body: some View {
        @Bindable var look = look
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                Button { look.size = max(0, look.size - 1) } label: { Text("A").font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44) }
                Divider().frame(height: 24)
                Button { look.size = min(Look.sizes.count - 1, look.size + 1) } label: { Text("A").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 44) }
            }
            .buttonStyle(.plain)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 10) {
                ForEach(Look.themes) { t in
                    Button { look.theme = t.id } label: {
                        VStack(spacing: 6) {
                            Text("Aa").font(.system(size: 17, weight: .medium, design: .serif))
                                .frame(width: 52, height: 52)
                                .foregroundStyle(t.id == "original" ? Color.gray : Color(t.ink))
                                .background {
                                    if t.id == "original" {
                                        LinearGradient(stops: [.init(color: .white, location: 0.5), .init(color: Color(white: 0.12), location: 0.5)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                    } else {
                                        Color(t.background)
                                    }
                                }
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(look.theme == t.id ? Color.accentColor : Color.primary.opacity(0.15),
                                                               lineWidth: look.theme == t.id ? 2.5 : 0.5))
                            Text(t.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Font")
                    Spacer()
                    Picker("Font", selection: $look.font) {
                        ForEach(Look.fonts, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, 2)
                Divider()
                Toggle("Justify text", isOn: $look.justify).padding(.vertical, 8)
                Divider()
                Toggle("Colour dialogue by character", isOn: $look.colorDialogue).padding(.vertical, 8)
            }
            .padding(.horizontal, 14)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(20)
        .tint(.accentColor)
    }
}

/// Who has a voice in the book, as in the Mac's Cast panel, with a sample of each voice.
struct CastSheet: View {
    @Environment(Player.self) private var player
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(player.cast.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { m in
                        CastRow(member: m)
                    }
                } footer: {
                    Text("Change voices, rename characters and re-cast in RealBook on your Mac. Hold a line on the page to change who says it.")
                }
            }
            .navigationTitle("Cast")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search characters")
        }
    }
}

struct CastRow: View {
    @Environment(Player.self) private var player
    let member: CastMember

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(member.color.map { Color(UIColor(hex: $0)) } ?? Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(member.name).font(.body.weight(.semibold))
                    Spacer()
                    if let n = member.lines, n > 0 {
                        Text("\(n) line\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = member.summary, !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                if let voice = member.voice, !voice.isEmpty {
                    Text(voice).font(.footnote).italic().foregroundStyle(.secondary).lineLimit(3)
                }
            }
            if member.sample != nil {
                Button { player.sample(member) } label: {
                    Group {
                        if player.sampling == member.id {
                            Image(systemName: "stop.circle.fill")
                        } else {
                            Image(systemName: "play.circle")
                        }
                    }
                    .font(.title2)
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hear \(member.name)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Who says this?": gives a quote to someone else in the cast, on the Mac.
struct SpeakerPicker: View {
    @Environment(Player.self) private var player
    let segment: Int
    let close: () -> Void
    @State private var search = ""
    @State private var saving = false

    var body: some View {
        let line = player.page.first { $0.segment == segment }
        NavigationStack {
            List {
                if let line {
                    Section {
                        Text("“\(line.text)”").font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                Section {
                    ForEach(player.cast.filter { !$0.id.isEmpty && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { m in
                        row(m.name, color: m.color, chosen: line?.speaker == m.id) { choose(m.id) }
                    }
                    if search.isEmpty {
                        row("Unknown (narrator reads it)", color: nil, chosen: line?.speaker == nil) { choose(nil) }
                    }
                }
            }
            .navigationTitle("Who Says This?")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search characters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                if saving { ToolbarItem(placement: .confirmationAction) { ProgressView() } }
            }
            .disabled(saving)
        }
    }

    private func row(_ name: String, color: String?, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(color.map { Color(UIColor(hex: $0)) } ?? Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
                Text(name).foregroundStyle(.primary)
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
        }
    }

    private func choose(_ speaker: String?) {
        saving = true
        Task {
            await player.setSpeaker(speaker, segment: segment)
            close()
        }
    }
}
