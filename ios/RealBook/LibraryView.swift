import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var pairing = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !library.paired {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pair with your Mac").font(.headline)
                            Text("Open RealBook on your Mac, go to Listen on iPhone, turn it on and scan the code.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Pair") { pairing = true }.buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                }
                Section("On this iPhone") {
                    if library.books.isEmpty {
                        Text("Books you download from your Mac play here, even without Wi‑Fi.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(library.books) { b in
                        NavigationLink(value: b.id) { LocalRow(book: b) }
                    }
                    .onDelete { rows in
                        for i in rows { library.remove(library.books[i].id) }
                    }
                }
                if library.paired { macSection }
            }
            .navigationTitle("RealBook")
            .navigationDestination(for: String.self) { id in PlayerView(bookID: id) }
            .refreshable { await library.sync() }
            .toolbar {
                if library.paired {
                    Menu {
                        Button("Pair Again") { pairing = true }
                        Button("Forget This Mac", role: .destructive) { library.mac.unpair(); Task { await library.sync() } }
                    } label: { Image(systemName: "laptopcomputer") }
                }
            }
            .sheet(isPresented: $pairing) {
                PairView { link in
                    library.mac.pair(link)
                    pairing = false
                    Task { await library.sync() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let id = player.bookID, path.last != id, let b = library.book(id) {
                    MiniPlayer(book: b) { path.append(id) }
                }
            }
            .task(id: library.remote.contains { $0.export.state == "running" }) {
                // While the Mac makes an offline copy, check on it now and then.
                while !Task.isCancelled, library.remote.contains(where: { $0.export.state == "running" }) {
                    try? await Task.sleep(for: .seconds(4))
                    await library.sync()
                }
            }
        }
    }

    private var macSection: some View {
        Section {
            if !library.reachable {
                Label(library.lastError ?? "Looking for your Mac…", systemImage: "wifi.exclamationmark")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(library.remote.filter { library.book($0.id) == nil || library.hasUpdate($0) || library.downloads[$0.id] != nil }) { r in
                RemoteRow(book: r)
            }
        } header: {
            Text("On your Mac")
        } footer: {
            if library.reachable {
                Text("An offline copy is the whole book made into audio once, with the voices from your Mac. Your place in each book stays in step with the Mac.")
            }
        }
    }
}

struct LocalRow: View {
    @Environment(Library.self) private var library
    let book: LocalBook

    var body: some View {
        HStack(spacing: 12) {
            BookCover(id: book.id, title: book.title, hasCover: book.hasCover).frame(width: 44, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if book.durationMs > 0 {
                    ProgressView(value: Double(book.positionMs), total: Double(book.durationMs)).tint(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct RemoteRow: View {
    @Environment(Library.self) private var library
    let book: RemoteBook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.title).font(.headline).lineLimit(2)
            if let p = library.downloads[book.id] {
                ProgressView(value: p) { Text("Downloading…").font(.caption) }.tint(.orange)
            } else if book.export.state == "running" {
                let done = Double(book.export.done ?? 0), total = Double(max(1, book.export.total ?? 1))
                ProgressView(value: done, total: total) {
                    Text("Your Mac is making the offline copy").font(.caption)
                } currentValueLabel: {
                    Text(book.export.message ?? "").font(.caption2).lineLimit(2)
                }.tint(.orange)
            } else if book.export.ready {
                Button(library.hasUpdate(book) ? "Download Update (\(size))" : "Download (\(size))") {
                    Task { await library.download(book) }
                }.buttonStyle(.bordered)
            } else {
                Text(book.export.file != nil ? "The offline copy on your Mac is too old for this app." : "No offline copy yet.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Make Offline Copy on Mac") { Task { await library.makeOfflineCopy(book) } }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: book.export.bytes ?? 0, countStyle: .file)
    }
}

struct BookCover: View {
    let id: String
    let title: String
    let hasCover: Bool

    var body: some View {
        Group {
            if hasCover, let image = UIImage(contentsOfFile: Library.cover(of: id).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
                    .overlay(Text(title).font(.caption2.bold()).foregroundStyle(.white).padding(4).multilineTextAlignment(.center))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    let book: LocalBook
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookCover(id: book.id, title: book.title, hasCover: book.hasCover).frame(width: 34, height: 48)
            VStack(alignment: .leading) {
                Text(book.title).font(.subheadline.bold()).lineLimit(1)
                if let t = player.timeline, t.chapters.indices.contains(player.chapter) {
                    Text(t.chapters[player.chapter].title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}
