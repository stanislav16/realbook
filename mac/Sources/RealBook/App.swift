import AppKit
import Observation
import SwiftUI

@main
struct RealBookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("RealBook", id: "main") {
            Root().environment(model).frame(minWidth: 860, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 880)
        .commands { Menus(model: model) }

        Settings {
            SettingsScreen().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    /// Space and the arrows work the player, as long as nobody is typing: a menu's shortcut would take
    /// them from the text fields.
    /// Whether the key was used.
    @MainActor private func keys(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard let model = Self.model, let reader = model.reader, flags.intersection([.command, .option, .control]).isEmpty,
              !(NSApp.keyWindow?.firstResponder is NSText), NSApp.keyWindow?.sheets.isEmpty ?? true, NSApp.modalWindow == nil else { return false }
        switch code {
        case 49: reader.toggle()
        case 123: reader.step(-1)
        case 124: reader.step(1)
        default: return false
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode, flags = event.modifierFlags
            return MainActor.assumeIsolated { self?.keys(code, flags) ?? false } ? nil : event
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The iPhone may have moved on while this was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await Self.model?.reader?.catchUp() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // also when run from the build folder while developing
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The window's whole state: the library, the book open in it, and what the engine says.
@MainActor
@Observable
final class AppModel {
    struct Book: Codable, Identifiable, Hashable {
        var id: String
        var title: String
        var author: String
        var created: Double?
        var opened: Double?
        var analyzer: String?
        var chapters: Int
        var characters: Int?
        var cover: String?
        var progress: Double
        var finished: Bool?
        var position: MacPosition

        static func == (a: Book, b: Book) -> Bool { a.id == b.id && a.progress == b.progress && a.title == b.title && a.cover == b.cover }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case reading = "Reading Now", all = "All Books", finished = "Finished", phone = "Listen on iPhone"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .reading: "book"
            case .all: "books.vertical"
            case .finished: "checkmark.circle"
            case .phone: "iphone"
            }
        }
    }

    private let engine = Engine()
    private(set) var api: API?
    var failed: String?
    var books: [Book] = []
    var filter = Filter.reading
    var search = ""
    var reader: Reader?
    var look = Look()
    var config: [String: Any] = [:]
    var message: String?
    var exportOnOpen = false
    private var messageTimer: Task<Void, Never>?

    var canExport: Bool { config["export"] as? Bool ?? false }

    func start() async {
        guard api == nil else { return }
        AppDelegate.model = self
        do {
            let api = API(base: try await engine.start())
            self.api = api
            look.onChange = { values in Task { _ = try? await api.data("api/settings", method: "PUT", json: ["appearance": values]) } }
            await refreshConfig()
            if let appearance = config["appearance"] as? [String: Any] { look.apply(appearance) }
            await refreshBooks()
            if !books.contains(where: { ($0.progress) > 0 && $0.finished != true }) { filter = .all }
        } catch {
            failed = error.localizedDescription
        }
    }

    func refreshConfig() async {
        if let c = try? await api?.object("api/config") { config = c }
    }

    func refreshBooks() async {
        if let list = try? await api?.get([Book].self, "api/books") { books = list }
    }

    var continueBook: Book? {
        books.filter { $0.progress > 0 && $0.finished != true }.max { ($0.opened ?? 0) < ($1.opened ?? 0) }
    }

    var shown: [Book] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = books.filter { q.isEmpty || "\($0.title) \($0.author)".lowercased().contains(q) }
        switch filter {
        case .reading: list = list.filter { $0.progress > 0 && $0.finished != true }.sorted { ($0.opened ?? 0) > ($1.opened ?? 0) }
        case .finished: list = list.filter { $0.finished == true }
        default: break
        }
        return list
    }

    func open(_ id: String, play: Bool = false) {
        guard let api else { return }
        let reader = Reader(id: id, api: api)
        reader.connectSystemControls()
        self.reader = reader
        Task {
            await reader.open()
            if play { reader.play() }
        }
    }

    func closeBook() {
        reader?.pause()
        reader?.disconnectSystemControls()
        reader = nil
        Task { await refreshBooks() }
    }

    func say(_ text: String, seconds: Double = 3.5) {
        message = text
        messageTimer?.cancel()
        messageTimer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { message = nil }
        }
    }

    /// The Open panel: book files, and EPUB folders (Apple Books exports those).
    func pickBookPaths(multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an EPUB or text file. Books dragged out of Apple Books work too."
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls : []
    }

    func addBooks(_ urls: [URL]? = nil) {
        guard let api else { return }
        let urls = urls ?? pickBookPaths(multiple: true)
        Task {
            for url in urls {
                say("Reading “\(url.lastPathComponent)” and finding its characters…", seconds: 120)
                do {
                    let d = try await api.data("api/books/from-path", method: "POST", json: ["path": url.path])
                    let book = try JSONDecoder().decode(Book.self, from: d)
                    say("Added “\(book.title)”")
                    await refreshBooks()
                    open(book.id)
                } catch {
                    say(error.localizedDescription, seconds: 6)
                }
            }
        }
    }

    func updateFromFile(_ book: Book) {
        guard let api, let url = pickBookPaths(multiple: false).first else { return }
        Task {
            say("Reading “\(url.lastPathComponent)”…", seconds: 120)
            do {
                let r = try await api.object("api/books/\(book.id)/source-path", method: "POST", json: ["path": url.path])
                say(r["kept_text"] as? Bool == true ? "Updated “\(book.title)”. Your place is kept."
                    : "Updated “\(book.title)” from the new file. Characters were found again; your place is about the same.", seconds: 6)
                await refreshBooks()
            } catch {
                say(error.localizedDescription, seconds: 6)
            }
        }
    }

    func remove(_ book: Book) {
        guard let api else { return }
        Task {
            _ = try? await api.data("api/books/\(book.id)", method: "DELETE")
            await refreshBooks()
        }
    }
}

struct Root: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottom) {
            if let reader = model.reader {
                ReaderScreen(reader: reader).transition(.opacity)
            } else if let failed = model.failed {
                ContentUnavailableView("RealBook couldn't start", systemImage: "exclamationmark.triangle", description: Text(failed))
            } else if model.api == nil {
                ProgressView("Opening your library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryScreen().transition(.opacity)
            }
            if let message = model.message {
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(in: Capsule())
                    .padding(.bottom, model.reader == nil ? 28 : 150)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.message)
        .animation(.easeInOut(duration: 0.2), value: model.reader == nil)
        .task {
            await model.start()
            #if DEBUG
            await DebugScript.run(model)
            #endif
        }
        .onAppear { schemeChanged(scheme) }
        .onChange(of: scheme) { _, now in schemeChanged(now) }
    }
}

extension Root {
    /// Black in dark mode, as on the iPhone, not the system's grey; the glass takes its colour from this.
    private func schemeChanged(_ now: ColorScheme) {
        model.look.systemDark = now == .dark
        for window in NSApp.windows { window.backgroundColor = now == .dark ? .black : .white }
    }
}

struct Menus: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Book…") { model.addBooks() }.keyboardShortcut("o")
            Divider()
            Button("Library") { model.closeBook() }.keyboardShortcut("l").disabled(model.reader == nil)
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { model.reader?.toggle() }.disabled(model.reader == nil)
            Button("Next Line") { model.reader?.step(1) }.disabled(model.reader == nil)
            Button("Previous Line") { model.reader?.step(-1) }.disabled(model.reader == nil)
            Divider()
            Button("Next Chapter") { model.reader.map { $0.goTo(chapter: $0.chapter + 1) } }.keyboardShortcut(.rightArrow)
                .disabled(model.reader.map { $0.chapter + 1 >= $0.chapterTitles.count } ?? true)
            Button("Previous Chapter") { model.reader.map { $0.goTo(chapter: $0.chapter - 1) } }.keyboardShortcut(.leftArrow)
                .disabled(model.reader.map { $0.chapter == 0 } ?? true)
        }
        CommandMenu("Book") {
            Button("Show Text") {
                model.look.showText.toggle()
                model.look.changed()
            }.keyboardShortcut("3").disabled(model.reader == nil)
            Button("Show Contents") { NotificationCenter.default.post(name: .togglePanel, object: "toc") }.keyboardShortcut("1").disabled(model.reader == nil)
            Button("Show Cast") { NotificationCenter.default.post(name: .togglePanel, object: "cast") }.keyboardShortcut("2").disabled(model.reader == nil)
        }
    }
}

extension Notification.Name {
    static let togglePanel = Notification.Name("realbook.togglePanel")
}
