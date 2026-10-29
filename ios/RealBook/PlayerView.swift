import SwiftUI

struct PlayerView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let bookID: String
    @State private var scrubbing: Double?
    @State private var chapters = false

    var body: some View {
        if let book = library.book(bookID) {
            content(book).onAppear { player.open(book, library: library) }
        } else {
            ContentUnavailableView("This book isn't on your iPhone anymore", systemImage: "book.closed")
        }
    }

    private func content(_ book: LocalBook) -> some View {
        VStack(spacing: 18) {
            BookCover(id: book.id, title: book.title, hasCover: book.hasCover)
                .frame(width: 120, height: 176)
                .shadow(radius: 8, y: 4)
            VStack(spacing: 4) {
                Text(book.title).font(.headline).multilineTextAlignment(.center)
                if let t = player.timeline, t.chapters.indices.contains(player.chapter) {
                    Text(t.chapters[player.chapter].title).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            currentLine
            Spacer(minLength: 0)
            scrubber
            controls
            HStack {
                Menu {
                    Picker("Speed", selection: Bindable(player).speed) {
                        ForEach(Player.speeds, id: \.self) { Text(speedLabel($0)).tag($0) }
                    }
                } label: {
                    Label(speedLabel(player.speed), systemImage: "gauge.with.dots.needle.33percent")
                }
                Spacer()
                Button { chapters = true } label: { Label("Chapters", systemImage: "list.bullet") }
            }
            .font(.subheadline)
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $chapters) { ChapterList(close: { chapters = false }) }
    }

    /// The line being read, and who says it.
    private var currentLine: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let line = player.line {
                    if let who = player.speakerName(line) {
                        Text(who.uppercased()).font(.caption.bold()).foregroundStyle(.orange)
                    }
                    Text(line.text)
                        .font(.system(.title3, design: .serif))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(line.speaker == nil ? .primary : Color.orange)
                        .animation(.default, value: line.ms)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: 220)
    }

    private var scrubber: some View {
        let total = Double(max(1, player.durationMs))
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { scrubbing ?? Double(player.ms) }, set: { scrubbing = $0 }), in: 0...total) { editing in
                if !editing, let s = scrubbing {
                    player.seek(to: Int(s))
                    scrubbing = nil
                }
            }
            .tint(.orange)
            HStack {
                Text(time(Int(scrubbing ?? Double(player.ms))))
                Spacer()
                Text("−" + time(player.durationMs - Int(scrubbing ?? Double(player.ms))))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            Button { player.previousLine() } label: { Image(systemName: "backward.end.fill") }
            Button { player.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
            }
            Button { player.skip(seconds: 30) } label: { Image(systemName: "goforward.30") }
            Button { player.nextLine() } label: { Image(systemName: "forward.end.fill") }
        }
        .font(.title2)
        .tint(.primary)
    }

    private func speedLabel(_ s: Float) -> String {
        s == 1 ? "1×" : String(format: "%g×", s)
    }

    private func time(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ChapterList: View {
    @Environment(Player.self) private var player
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array((player.timeline?.chapters ?? []).enumerated()), id: \.offset) { i, c in
                        Button {
                            player.goTo(chapter: i)
                            close()
                        } label: {
                            HStack {
                                Text(c.title).foregroundStyle(.primary)
                                Spacer()
                                if i == player.chapter { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.orange) }
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
