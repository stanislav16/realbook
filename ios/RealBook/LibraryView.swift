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
    var lastListened: Double { max(local?.positionUpdated ?? 0, remote?.position.updated ?? 0, remote?.opened ?? 0) }
    var finished: Bool { remote?.finished ?? (progress >= 0.999) }
    var started: Bool { progress > 0 && !finished }
}

struct OpenBook: Identifiable { var id: String }

/// The Mac's sidebar: Reading Now, All Books, Finished.
enum Shelf: String, CaseIterable {
    case reading = "Reading Now", all = "All Books", finished = "Finished"
}

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var pairing = false
    @State private var open: OpenBook?
    @State private var filter = Shelf(rawValue: UserDefaults.standard.string(forKey: "shelf") ?? "") ?? .all
    @State private var search = ""

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
        return books.filter(\.started).max { $0.lastListened < $1.lastListened }
    }

    private var shown: [ShelfBook] {
        var books = shelf.filter { search.isEmpty || "\($0.title) \($0.author)".localizedCaseInsensitiveContains(search) }
        switch filter {
        case .reading: books = books.filter(\.started).sorted { $0.lastListened > $1.lastListened }
        case .finished: books = books.filter(\.finished)
        case .all: break
        }
        return books
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !library.paired { pairCard }
                    if !shelf.isEmpty {
                        Picker("Show", selection: $filter) {
                            ForEach(Shelf.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: filter) { _, f in UserDefaults.standard.set(f.rawValue, forKey: "shelf") }
                    }
                    if let book = current, search.isEmpty, filter != .finished {
                        ContinueCard(book: book) { play in
                            if play { player.open(book.id, library: library, play: true) }
                            open = OpenBook(id: book.id)
                        }
                    }
                    if !shelf.isEmpty {
                        let books = shown
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 18, alignment: .top)], spacing: 22) {
                            ForEach(books) { book in
                                Button { open = OpenBook(id: book.id) } label: { ShelfTile(book: book) }
                                    .buttonStyle(.plain)
                                    .contextMenu { menu(for: book) }
                            }
                        }
                        if books.isEmpty {
                            Text(!search.isEmpty ? "No books match your search."
                                 : filter == .reading ? "Books you've started will appear here."
                                 : "Books you finish will appear here.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    }
                    if library.paired { macStatus }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("RealBook")
            .searchable(text: $search, prompt: "Search")
            .fullScreenCover(item: $open) { book in
                PlayerScreen(bookID: book.id) { open = nil }
                    .presentationBackground(.clear)  // the library shows behind it while it's dragged down
            }
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
                if let id = player.bookID {
                    MiniPlayer(id: id) { open = OpenBook(id: id) }
                }
            }
            #if DEBUG
            .task {
                // For trying screens in the simulator: launch with `-openBook <id>`.
                if let id = UserDefaults.standard.string(forKey: "download") {  // `-download <id>`
                    if library.remoteBook(id) == nil { await library.sync() }
                    if let r = library.remoteBook(id) { await library.download(r) }
                }
                if let id = UserDefaults.standard.string(forKey: "openBook"), open == nil { open = OpenBook(id: id) }
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
                 ? "Connected to your Mac. The next hours of the book you're listening to are saved here by themselves, for when you leave."
                 : "Your Mac isn't near. You can keep listening to what's saved on this iPhone.")
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}

/// The book you're in, to carry on with one tap: the same card as at the top of the Mac's library.
struct ContinueCard: View {
    @Environment(Player.self) private var player
    let book: ShelfBook
    let open: (_ play: Bool) -> Void

    var body: some View {
        let playing = player.bookID == book.id && player.playing
        HStack(spacing: 16) {
            BookCover(id: book.id, title: book.title, author: book.author).frame(width: 84, height: 126)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text("CONTINUE LISTENING").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(book.title).font(.system(.title3, design: .serif).weight(.semibold)).lineLimit(2)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                ProgressView(value: book.progress).padding(.vertical, 3)
                Button {
                    if player.bookID == book.id { player.toggle() } else { open(true) }
                } label: {
                    Label(playing ? "Pause" : "Resume", systemImage: playing ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Color(uiColor: .label), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(false) }
    }

    /// "Frank Herbert · Chapter 3 of 48 · 12%", as on the Mac.
    private var meta: String {
        var parts = [book.author].filter { !$0.isEmpty }
        if let r = book.remote, let n = r.chapters { parts.append("Chapter \(r.position.chapter + 1) of \(n)") }
        parts.append("\(max(1, Int(book.progress * 100)))%")
        return parts.joined(separator: " · ")
    }
}

/// A cover on the shelf, with where the book is and how far through.
struct ShelfTile: View {
    @Environment(Library.self) private var library
    let book: ShelfBook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCover(id: book.id, title: book.title, author: book.author)
                .aspectRatio(2 / 3, contentMode: .fit)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            progress
            Text(book.title).font(.caption.weight(.semibold)).lineLimit(2)
            Text(state).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// As under the Mac's covers: NEW, how far through, or Finished.
    @ViewBuilder private var progress: some View {
        if book.finished {
            Text("Finished").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        } else if book.progress > 0 {
            HStack(spacing: 6) {
                ProgressView(value: book.progress).scaleEffect(y: 0.7)
                Text("\(max(1, Int(book.progress * 100)))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("NEW").font(.caption2.weight(.bold)).tracking(0.4)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(.secondary)
                .background(.fill.secondary, in: Capsule())
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
        if let at = book.remote?.position, let saved = library.kept.note(chapter: at.chapter, segment: at.segment, of: book.id) { return saved }
        return library.reachable ? "Live from your Mac" : "On your Mac"
    }
}

/// A book's cover, from its offline copy or the Mac.
struct BookCover: View {
    @Environment(Library.self) private var library
    let id: String
    let title: String
    var author = ""
    @State private var image: UIImage?

    var body: some View {
        CoverImage(image: image, title: title, author: author)
            .task(id: id) { image = await library.cover(id) }
    }
}

struct CoverImage: View {
    let image: UIImage?
    let title: String
    var author = ""
    var radius: CGFloat = 4

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // The Mac's cover for a book without one: its colours, the title and the author.
                let (top, bottom) = coverGradients[titleHash(title) % coverGradients.count]
                GeometryReader { g in
                    let w = g.size.width
                    LinearGradient(colors: [Color(UIColor(hex: top)), Color(UIColor(hex: bottom))],
                                   startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.28), lineWidth: 1).padding(w * 0.06)
                        }
                        .overlay {
                            VStack(spacing: 0) {
                                Text(title).font(.system(size: max(5, w * 0.12), weight: .semibold, design: .serif))
                                    .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.6)
                                Spacer(minLength: 0)
                                if !author.isEmpty && w > 60 {
                                    Text(author.uppercased()).font(.system(size: max(5, w * 0.068))).tracking(w * 0.008)
                                        .multilineTextAlignment(.center).lineLimit(2).opacity(0.85)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.top, w * 0.24).padding(.horizontal, w * 0.12).padding(.bottom, w * 0.14)
                            .opacity(w > 40 ? 1 : 0)
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

/// The book playing, above the shelf: who's speaking and the chapter, as in the Mac's player.
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    let id: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookCover(id: id, title: player.title).frame(width: 34, height: 51)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(player.current?.color.map { Color(UIColor(hex: $0)) } ?? Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                    Text(player.current?.speaker ?? "Narrator").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(player.chapterTitles.indices.contains(player.chapter) ? player.chapterTitles[player.chapter] : player.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
