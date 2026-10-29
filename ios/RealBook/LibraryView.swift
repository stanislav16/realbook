import SwiftUI

/// A book on the shelf: on this iPhone, on the Mac, or both.
struct ShelfBook: Identifiable {
    var local: LocalBook?
    var remote: RemoteBook?

    var id: String { local?.id ?? remote!.id }
    var title: String { local?.title ?? remote!.title }
    var author: String { local?.author ?? remote!.author }
    var progress: Double {
        if let l = local, l.durationMs > 0 { return Double(l.positionMs) / Double(l.durationMs) }
        return remote?.progress ?? 0
    }
    var lastListened: Double { max(local?.positionUpdated ?? 0, remote?.position.updated ?? 0) }
}

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var pairing = false
    @State private var path: [String] = []

    private var shelf: [ShelfBook] {
        let remote = Dictionary(uniqueKeysWithValues: library.remote.map { ($0.id, $0) })
        var books = library.books.map { ShelfBook(local: $0, remote: remote[$0.id]) }
        let here = Set(books.map(\.id))
        books += library.remote.filter { !here.contains($0.id) }.map { ShelfBook(local: nil, remote: $0) }
        return books
    }

    /// The book to carry on with: the one playing, else the one listened to last.
    private var current: ShelfBook? {
        let books = shelf
        if let id = player.bookID, let b = books.first(where: { $0.id == id }) { return b }
        return books.filter { $0.progress > 0 && $0.progress < 0.999 }.max { $0.lastListened < $1.lastListened }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !library.paired { pairCard }
                    if let book = current {
                        ContinueCard(book: book) { path.append(book.id) }
                    }
                    if !shelf.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Library").font(.title2.bold())
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 18, alignment: .top)], spacing: 22) {
                                ForEach(shelf) { book in
                                    Button { path.append(book.id) } label: { ShelfTile(book: book) }
                                        .buttonStyle(.plain)
                                        .contextMenu { menu(for: book) }
                                }
                            }
                        }
                    }
                    if library.paired { macStatus }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("RealBook")
            .navigationDestination(for: String.self) { id in PlayerView(bookID: id) }
            .refreshable { await library.sync() }
            .toolbar {
                if library.paired {
                    Menu {
                        Button("Pair Again", systemImage: "qrcode.viewfinder") { pairing = true }
                        Button("Forget This Mac", systemImage: "xmark.circle", role: .destructive) {
                            library.mac.unpair()
                            Task { await library.sync() }
                        }
                    } label: {
                        Image(systemName: library.reachable ? "laptopcomputer" : "laptopcomputer.slash")
                    }
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
                if let id = player.bookID, path.last != id {
                    MiniPlayer(id: id) { path.append(id) }
                }
            }
            #if DEBUG
            .task {
                // For trying screens in the simulator: launch with `-openBook <id>`.
                if let id = UserDefaults.standard.string(forKey: "download") {  // `-download <id>`
                    if library.remoteBook(id) == nil { await library.sync() }
                    if let r = library.remoteBook(id) { await library.download(r) }
                }
                if let id = UserDefaults.standard.string(forKey: "openBook"), path.isEmpty { path = [id] }
            }
            #endif
            .task(id: library.remote.contains { $0.export.state == "running" }) {
                // While the Mac makes an offline copy, check on it now and then.
                while !Task.isCancelled, library.remote.contains(where: { $0.export.state == "running" }) {
                    try? await Task.sleep(for: .seconds(4))
                    await library.sync()
                }
            }
        }
        .tint(.primary)
    }

    @ViewBuilder private func menu(for book: ShelfBook) -> some View {
        if let r = book.remote {
            if r.export.ready && (book.local == nil || library.hasUpdate(r)) {
                Button(book.local == nil ? "Download Offline Copy" : "Download Update", systemImage: "arrow.down.circle") {
                    Task { await library.download(r) }
                }
            } else if !r.export.ready && r.export.state != "running" {
                Button("Make Offline Copy on Mac", systemImage: "square.and.arrow.down.on.square") {
                    Task { await library.makeOfflineCopy(r) }
                }
            }
        }
        if book.local != nil {
            Button("Remove from iPhone", systemImage: "trash", role: .destructive) { library.remove(book.id) }
        }
    }

    private var pairCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "laptopcomputer.and.iphone").font(.largeTitle).foregroundStyle(.secondary)
            Text("Pair with your Mac").font(.title3.bold())
            Text("Open RealBook on your Mac, choose Listen on iPhone in the sidebar, turn it on and scan the code.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { pairing = true } label: { Text("Pair").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(18)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var macStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: library.reachable ? "checkmark.circle" : "wifi.exclamationmark")
            Text(library.reachable
                 ? "Connected to your Mac. Tap a book to listen live, or hold it to download its offline copy for listening anywhere."
                 : library.lastError ?? "Looking for your Mac…")
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}

/// The book you're in, to carry on with one tap.
struct ContinueCard: View {
    @Environment(Player.self) private var player
    let book: ShelfBook
    let open: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            BookCover(id: book.id, title: book.title).frame(width: 84, height: 126)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text("CONTINUE LISTENING").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(book.title).font(.system(.title3, design: .serif).weight(.semibold)).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: book.progress).padding(.top, 4)
                HStack {
                    Text("\(Int(book.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if player.bookID == book.id { player.toggle() } else { open() }
                    } label: {
                        Image(systemName: player.bookID == book.id && player.playing ? "pause.fill" : "play.fill")
                            .font(.title3).frame(width: 44, height: 44)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .background(Color(uiColor: .label), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

/// A cover on the shelf, with where the book is and how far through.
struct ShelfTile: View {
    @Environment(Library.self) private var library
    let book: ShelfBook

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BookCover(id: book.id, title: book.title)
                .aspectRatio(2 / 3, contentMode: .fit)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            if book.progress > 0 {
                ProgressView(value: book.progress).scaleEffect(y: 0.7)
            }
            Text(book.title).font(.caption.weight(.semibold)).lineLimit(2)
            Text(state).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var badge: some View {
        if let p = library.downloads[book.id] {
            ProgressView(value: p).progressViewStyle(.circular).padding(6).background(.ultraThinMaterial, in: Circle())
        } else if book.local != nil {
            Image(systemName: "arrow.down.circle.fill").font(.subheadline).symbolRenderingMode(.palette)
                .foregroundStyle(.black, .white).shadow(radius: 2)
        }
    }

    private var state: String {
        if library.downloads[book.id] != nil { return "Downloading…" }
        if let r = book.remote, r.export.state == "running" {
            return "Making offline copy · \(Int(100 * Double(r.export.done ?? 0) / Double(max(1, r.export.total ?? 1))))%"
        }
        if let r = book.remote, book.local != nil, library.hasUpdate(r) { return "Update available" }
        if book.local != nil { return "On this iPhone" }
        return library.reachable ? "Live from your Mac" : "On your Mac"
    }
}

/// A book's cover, from its offline copy or the Mac.
struct BookCover: View {
    @Environment(Library.self) private var library
    let id: String
    let title: String
    @State private var image: UIImage?

    var body: some View {
        CoverImage(image: image, title: title)
            .task(id: id) { image = await library.cover(id) }
    }
}

struct CoverImage: View {
    let image: UIImage?
    let title: String

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.32), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .bottomLeading) {
                        Text(title).font(.system(size: 9, weight: .semibold, design: .serif)).foregroundStyle(.white).padding(5)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    let id: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookCover(id: id, title: player.title).frame(width: 34, height: 51)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if player.chapterTitles.indices.contains(player.chapter) {
                    Text(player.chapterTitles[player.chapter]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.horizontal)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}
