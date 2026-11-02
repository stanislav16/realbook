import SwiftUI

/// The native sidebar (Liquid Glass by itself on macOS 26) and the shelf.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var removing: AppModel.Book?
    @State private var info: AppModel.Book?
    @State private var dropping = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.filter }, set: { if let f = $0 { model.filter = f } })) {
                Section("Library") {
                    ForEach([AppModel.Filter.reading, .all, .finished]) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                Section("Devices") {
                    Label(AppModel.Filter.phone.rawValue, systemImage: AppModel.Filter.phone.icon).tag(AppModel.Filter.phone)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                SettingsLink { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10)
            }
        } detail: {
            Group {
                if model.filter == .phone {
                    PhoneScreen()
                } else {
                    shelf
                }
            }
            .navigationTitle(model.filter.rawValue)
            .searchable(text: $model.search, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Book", systemImage: "plus") { model.addBooks() }
                }
            }
        }
        .confirmationDialog("Remove “\(removing?.title ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removing.map(model.remove) }
        } message: {
            Text("The book and its saved audio will be deleted from RealBook. The original file you imported is not touched.")
        }
        .sheet(item: $info) { BookInfo(book: $0) }
    }

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VoiceBanner()
                if model.search.isEmpty, model.filter != .finished, let book = model.continueBook { continueCard(book) }
                if model.shown.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: model.filter.icon).frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 30, alignment: .bottom)], spacing: 34) {
                        ForEach(model.shown) { tile($0) }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, lineWidth: 2).padding(8).allowsHitTesting(false) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addBooks(urls)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
    }

    private var emptyTitle: String {
        switch model.filter {
        case .reading: "Books you've started will appear here."
        case .finished: "Books you finish will appear here."
        default: model.search.isEmpty ? "Add a book to start listening." : "No books match."
        }
    }

    private func continueCard(_ book: AppModel.Book) -> some View {
        HStack(spacing: 18) {
            BookCover(book: book).frame(width: 84, height: 126)
            VStack(alignment: .leading, spacing: 6) {
                Text("CONTINUE LISTENING").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(book.title).font(.system(.title3, design: .serif).weight(.semibold)).lineLimit(2)
                Text([book.author, "Chapter \(book.position.chapter + 1) of \(book.chapters)", "\(Int(book.progress * 100))%"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: book.progress).frame(maxWidth: 320)
                Button("Resume", systemImage: "play.fill") { model.open(book.id, play: true) }
                    .buttonStyle(.borderedProminent).controlSize(.regular).padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 680)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func tile(_ book: AppModel.Book) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.open(book.id) } label: {
                BookCover(book: book).aspectRatio(2 / 3, contentMode: .fit).shadow(color: .black.opacity(0.25), radius: 10, y: 6)
            }
            .buttonStyle(CoverPress())
            .help(book.author.isEmpty ? book.title : "\(book.title) by \(book.author)")
            HStack(spacing: 6) {
                if book.finished == true {
                    Text("Finished").font(.caption).foregroundStyle(.secondary)
                } else if book.progress > 0 {
                    ProgressView(value: book.progress).controlSize(.small)
                    Text("\(Int(book.progress * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("NEW").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1).background(.tint, in: Capsule()).foregroundStyle(.background)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Book Info…") { info = book }
                    Button("Update from File…") { model.updateFromFile(book) }
                    if model.canExport {
                        Button("Export Audiobook…") {
                            model.exportOnOpen = true
                            model.open(book.id)
                        }
                    }
                    Divider()
                    Button("Remove Book…", role: .destructive) { removing = book }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Circle())
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GlassButton())
                .fixedSize()
            }
        }
    }
}

/// Offers the natural voices until there are some.
struct VoiceBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let k = model.config["kokoro"] as? [String: Any] ?? [:]
        let qwen = model.config["qwen"] as? [String: Any] ?? [:]
        if !k.isEmpty, k["installed"] as? Bool != true, qwen["installed"] as? Bool != true, model.config["hide_voice_banner"] as? Bool != true {
            let downloading = k["state"] as? String == "downloading"
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get natural-sounding voices").font(.callout.weight(.semibold))
                    Text(downloading ? k["message"] as? String ?? "" : "Kokoro voices sound far more human than the built-in ones. Free, offline, one-time \(Int((k["bytes"] as? Double ?? 0) / 1e6)) MB download.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(downloading ? "Downloading…" : "Download") {
                    guard let api = model.api else { return }
                    Task {
                        _ = try? await api.data("api/kokoro/install", method: "POST")
                        while !Task.isCancelled {
                            await model.refreshConfig()
                            if (model.config["kokoro"] as? [String: Any])?["state"] as? String != "downloading" { break }
                            try? await Task.sleep(for: .seconds(1))
                        }
                        if (model.config["kokoro"] as? [String: Any])?["installed"] as? Bool == true {
                            model.say("Natural voices installed. Every book has been re-cast with them", seconds: 6)
                        }
                    }
                }
                .disabled(downloading)
                Button {
                    guard let api = model.api else { return }
                    Task { model.config = (try? await api.object("api/settings", method: "PUT", json: ["hide_voice_banner": true])) ?? model.config }
                } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24) }
                    .buttonStyle(GlassButton()).help("Hide")
            }
            .padding(14)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct CoverPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }

    private struct Inner: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .offset(y: hovering ? -3 : 0)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: hovering)
        }
    }
}

struct BookCover: View {
    @Environment(AppModel.self) private var model
    let book: AppModel.Book
    var radius: CGFloat = 6

    var body: some View {
        Group {
            if book.cover != nil, let api = model.api {
                AsyncImage(url: api.url("api/books/\(book.id)/cover")) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { GeneratedCover(title: book.title, author: book.author) }
                }
            } else {
                GeneratedCover(title: book.title, author: book.author)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A cover for a book without one: the same colours as on the iPhone.
struct GeneratedCover: View {
    let title: String
    let author: String

    var body: some View {
        let pair = coverGradients[titleHash(title) % coverGradients.count]
        ZStack {
            LinearGradient(colors: [Color(nsColor: NSColor(hex: pair.0)), Color(nsColor: NSColor(hex: pair.1))], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading) {
                Text(title).font(.system(size: 17, weight: .semibold, design: .serif)).minimumScaleFactor(0.5)
                Spacer()
                Text(author.uppercased()).font(.system(size: 10)).tracking(1.2).opacity(0.7).lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BookInfo: View {
    @Environment(\.dismiss) private var dismiss
    let book: AppModel.Book

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(book.title).font(.headline)
            Grid(alignment: .leading, verticalSpacing: 6) {
                row("Author", book.author.isEmpty ? "Unknown" : book.author)
                row("Chapters", String(book.chapters))
                row("Characters", "\(book.characters ?? 0) with their own voice")
                row("Found by", book.analyzer == "claude" ? "Claude" : "RealBook's built-in character finder")
                row("Progress", book.finished == true ? "Finished" : "\(Int(book.progress * 100))%")
                if let created = book.created { row("Added", Date(timeIntervalSince1970: created).formatted(date: .abbreviated, time: .omitted)) }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v) }
    }
}
