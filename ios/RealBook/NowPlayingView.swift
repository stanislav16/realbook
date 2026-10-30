import SwiftUI

/// The book playing, full screen: its cover, the line being read between its neighbours, and the
/// bigger controls. Opened from the player at the bottom of the page.
struct NowPlayingView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let bookID: String
    let close: () -> Void
    @State private var scrubbing: Double?
    @State private var chapters = false
    @State private var cover: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                modeSwitch
                HStack {
                    Button(action: close) {
                        Image(systemName: "chevron.down").font(.body.weight(.semibold))
                            .frame(width: 36, height: 36).background(.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
            }
            .foregroundStyle(.white)
            .padding(.top, 14)
            CoverImage(image: cover, title: player.title)
                .frame(width: 132, height: 198)
                .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                .padding(.top, 18)
            VStack(spacing: 3) {
                Text(player.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                if player.chapterTitles.indices.contains(player.chapter) {
                    Text(player.chapterTitles[player.chapter]).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.top, 14)
            lines.frame(maxHeight: .infinity)
            if let problem = player.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.bottom, 8)
            }
            scrubber
            controls.padding(.vertical, 14)
            footer
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .presentationBackground(.black)
        .sheet(isPresented: $chapters) { ChapterList(close: { chapters = false }).presentationDetents([.medium, .large]) }
        .task(id: bookID) { cover = await library.cover(bookID) }
    }

    /// The cover, blurred, behind everything. In an overlay, so its size doesn't widen the page.
    private var backdrop: some View {
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

    /// Offline copy or live from the Mac, when both are possible.
    @ViewBuilder private var modeSwitch: some View {
        let canLive = library.reachable && library.remoteBook(bookID) != nil
        if player.hasOfflineCopy && canLive {
            Picker("Listen from", selection: Binding(get: { player.mode }, set: { player.switchTo($0) })) {
                Text("Offline copy").tag(Player.Mode.offline)
                Text("Live from Mac").tag(Player.Mode.live)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        } else {
            Label(player.mode == .live ? "Live from your Mac" : "Offline copy",
                  systemImage: player.mode == .live ? "dot.radiowaves.left.and.right" : "arrow.down.circle")
                .font(.caption.weight(.semibold)).textCase(.uppercase)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
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
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            Button { player.previousLine() } label: { Image(systemName: "backward.end.fill") }
            Spacer()
            if player.mode == .offline {
                Button { player.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }
                Spacer()
            }
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 68, height: 68)
                    if player.loading && player.playing {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .semibold)).foregroundStyle(.black)
                            .offset(x: player.playing ? 0 : 2)
                    }
                }
            }
            Spacer()
            if player.mode == .offline {
                Button { player.skip(seconds: 30) } label: { Image(systemName: "goforward.30") }
                Spacer()
            }
            Button { player.nextLine() } label: { Image(systemName: "forward.end.fill") }
        }
        .font(.title2)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        HStack {
            Menu {
                Picker("Speed", selection: Bindable(player).speed) {
                    ForEach(Player.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
            } label: {
                Text(Self.speedLabel(player.speed)).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            Spacer()
            sleepMenu
            Spacer()
            Button { chapters = true } label: {
                Label("Chapters", systemImage: "list.bullet").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    /// Stops playing after a while, or at the end of the chapter.
    private var sleepMenu: some View {
        Menu {
            Picker("Sleep Timer", selection: Binding(get: { player.sleep }, set: { player.setSleep($0) })) {
                Text("Off").tag(Player.Sleep.off)
                ForEach([5, 15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag(Player.Sleep.minutes($0)) }
                Text("End of Chapter").tag(Player.Sleep.endOfChapter)
            }
        } label: {
            Group {
                if let ends = player.sleepEnds {
                    Label { Text(timerInterval: Date.now...ends, countsDown: true).monospacedDigit() } icon: { Image(systemName: "moon.fill") }
                } else if player.sleep == .endOfChapter {
                    Label("Chapter end", systemImage: "moon.fill")
                } else {
                    Label("Sleep", systemImage: "moon.zzz")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
        }
    }

    static func speedLabel(_ s: Float) -> String { s == 1 ? "1×" : String(format: "%g×", s) }
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
