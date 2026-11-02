import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

private func sizeText(_ n: Int64) -> String { n >= 1_000_000_000 ? String(format: "%.1f GB", Double(n) / 1e9) : "\(n / 1_000_000) MB" }

/// Makes an .m4b audiobook of the whole book, to play offline in any audiobook app on any device.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reader: Reader
    @State private var status: RemoteBook.Export?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Audiobook").font(.headline)
            Text("Makes “\(reader.book?.title ?? "")” into an .m4b audiobook with chapters, read in the voices from the Cast. It plays offline in any audiobook app on iPhone, Android or Windows.").font(.callout).foregroundStyle(.secondary)
            if let s = status {
                if s.state == "running" {
                    ProgressView(value: Double(s.done ?? 0), total: Double(max(1, s.total ?? 1)))
                    Text(s.message ?? "").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel Export") { act("export/cancel") }
                } else {
                    if let m = s.message, s.state != "done" { Text(m).font(.caption).foregroundStyle(s.state == "error" ? .red : .secondary) }
                    if let file = s.file {
                        Text("\(s.state == "done" ? (s.message ?? "") + ". " : "")“\(file)” (\(sizeText(s.bytes ?? 0))), made \(Date(timeIntervalSince1970: s.made ?? 0).formatted()).").font(.caption)
                        HStack {
                            Button("Show in Finder") { act("export/reveal") }.buttonStyle(.borderedProminent)
                            Button("Export Again") { act("export") }
                        }
                    } else {
                        Button("Export") { act("export") }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ProgressView()
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 480)
        .task {
            while !Task.isCancelled {
                if let s = try? await reader.api.get(RemoteBook.Export.self, "api/books/\(reader.id)/export") { status = s }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func act(_ path: String) {
        Task {
            do { try await reader.api.data("api/books/\(reader.id)/\(path)", method: "POST") } catch { problem = error.localizedDescription }
        }
    }
}

/// Turning iPhone access on and off, the pairing code, and each book's offline copy.
struct PhoneScreen: View {
    @Environment(AppModel.self) private var model
    struct Status: Codable { var enabled: Bool; var running: Bool; var url: String? }
    struct Ahead: Codable { var state: String?; var enabled: Bool; var done: Int?; var total: Int?; var title: String? }
    @State private var remote: Status?
    @State private var ahead: Ahead?
    @State private var books: [RemoteBook] = []
    @State private var confirmReset = false

    private var api: API? { model.api }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card("Pair your iPhone") { pairing }
                card("Listening away from this computer") { away }
                card("Offline copies") { copies }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Make a new code?", isPresented: $confirmReset) {
            Button("New Code", role: .destructive) { post("api/remote/reset") }
        } message: {
            Text("Devices paired with the old code stop working.")
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var pairing: some View {
        if let r = remote, r.running, let url = r.url {
            HStack(alignment: .top, spacing: 16) {
                if let qr = qrImage(url) { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 170, height: 170).background(.white).clipShape(RoundedRectangle(cornerRadius: 10)) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("In the RealBook app on your iPhone, tap Pair and scan this code.")
                    Text("Or scan it with the Camera to listen in Safari, live from this Mac. Anyone with this code on your network can listen to your books.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Turn Off") { post("api/remote", json: ["enabled": false]) }
                        Button("New Code") { confirmReset = true }
                    }
                }
            }
        } else if remote?.running == true {
            Text("This Mac isn't connected to a network.").font(.caption).foregroundStyle(.secondary)
            Button("Turn Off") { post("api/remote", json: ["enabled": false]) }
        } else {
            Text("Let your iPhone reach RealBook over your Wi‑Fi, to download books and keep your place in step with this Mac.").font(.callout).foregroundStyle(.secondary)
            Button("Turn On") { post("api/remote", json: ["enabled": true]) }.buttonStyle(.borderedProminent)
        }
    }

    private var aheadNote: String {
        guard let a = ahead, a.enabled else { return "Off. The iPhone plays live, and offline copies still work." }
        let title = a.title ?? ""
        switch a.state {
        case "making": return "Making the next hours of “\(title)” for your iPhone: \(a.done ?? 0) of \(a.total ?? 0) lines. Your listening always goes first."
        case "battery": return "Waiting for this Mac to be plugged in, to make the next hours of “\(title)”."
        case "error": return "Couldn't make some lines of “\(title)”. It tries again the next time your iPhone connects."
        default: return title.isEmpty ? "Starts by itself when you open RealBook on your iPhone." : "The next hours of “\(title)” are ready: \(a.total ?? 0) lines."
        }
    }

    @ViewBuilder private var away: some View {
        Text("Your iPhone saves the next 4 hours of the book you're listening to, whenever it can reach this Mac, so you can leave without an offline copy.").font(.callout).foregroundStyle(.secondary)
        HStack {
            Text(aheadNote).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(ahead?.enabled == true ? "Turn Off" : "Turn On") { post("api/ahead", json: ["enabled": !(ahead?.enabled ?? false)]) }
        }
    }

    @ViewBuilder private var copies: some View {
        Text("The iPhone app plays a book offline from its offline copy: the whole book made into audio once, with the current voices. Making one takes as long as the book takes to make.").font(.callout).foregroundStyle(.secondary)
        ForEach(books) { b in
            HStack(spacing: 12) {
                if let book = model.books.first(where: { $0.id == b.id }) { BookCover(book: book, radius: 4).frame(width: 34, height: 51) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.title).font(.callout.weight(.medium)).lineLimit(1)
                    copyState(b.export)
                }
                Spacer()
                copyAction(b)
            }
        }
    }

    @ViewBuilder private func copyState(_ x: RemoteBook.Export) -> some View {
        if x.state == "running" {
            ProgressView(value: Double(x.done ?? 0), total: Double(max(1, x.total ?? 1)))
            Text(x.message ?? "").font(.caption).foregroundStyle(.secondary)
        } else if x.file != nil && x.phone == true {
            Text("Ready to download · \(sizeText(x.bytes ?? 0)) · made \(Date(timeIntervalSince1970: x.made ?? 0).formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(x.state == "error" ? (x.message ?? "") : x.file != nil ? "Made before the iPhone app; make it again to download it" : "Not made yet").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func copyAction(_ b: RemoteBook) -> some View {
        if b.export.state == "running" {
            Button("Cancel") { post("api/books/\(b.id)/export/cancel") }
        } else if b.export.file != nil && b.export.phone == true {
            Button("Update") { post("api/books/\(b.id)/export") }.help("Make it again, with the current voices")
        } else {
            Button("Make Offline Copy") { post("api/books/\(b.id)/export") }.buttonStyle(.borderedProminent)
        }
    }

    private func load() async {
        guard let api else { return }
        if let r = try? await api.get(Status.self, "api/remote") { remote = r }
        if let a = try? await api.get(Ahead.self, "api/ahead") { ahead = a }
        if let b = try? await api.get([RemoteBook].self, "api/phone/books") { books = b }
    }

    private func post(_ path: String, json: Any? = nil) {
        guard let api else { return }
        Task {
            do { try await api.data(path, method: "POST", json: json) } catch { model.say(error.localizedDescription, seconds: 6) }
            await load()
        }
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The app's native Settings window.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var problem: String?
    @State private var finder = false

    private var c: [String: Any] { model.config }
    private var kokoro: [String: Any] { c["kokoro"] as? [String: Any] ?? [:] }
    private var qwen: [String: Any] { c["qwen"] as? [String: Any] ?? [:] }

    var body: some View {
        Form {
            Section("Voices") {
                if kokoro["installed"] as? Bool != true { offer("kokoro", kokoro, "Natural voices (Kokoro) sound far more human than the built-in Mac voices. Free, and they run offline on this Mac.", button: "Download Natural Voices") }
                if kokoro["installed"] as? Bool == true || qwen["installed"] as? Bool == true {
                    Picker("Read books with", selection: Binding(get: { c["voice_engine"] as? String ?? "kokoro" }, set: { put(["voice_engine": $0]) })) {
                        if kokoro["installed"] as? Bool == true { Text("Natural voices (Kokoro)").tag("kokoro") }
                        if qwen["installed"] as? Bool == true { Text(qwen["label"] as? String ?? "Designed voices").tag("qwen") }
                        Text("Mac system voices").tag("apple")
                    }
                    if kokoro["installed"] as? Bool == true {
                        Toggle("With natural voices, use Mac voices for Scottish, Irish, Indian, Australian and South African characters, when one with that accent is installed", isOn: Binding(get: { c["apple_for_accents"] as? Bool ?? true }, set: { put(["apple_for_accents": $0]) }))
                    }
                    Text("Changing these re-casts every book. Voices you picked by hand are kept.").font(.caption).foregroundStyle(.secondary)
                }
                if qwen["supported"] as? Bool == true && qwen["installed"] as? Bool != true {
                    offer("qwen", qwen, "Designed voices make a voice for each character from how the book describes them, accents included, and you can rewrite any description. \(qwen["speed"] as? String ?? "")", button: "Download Designed Voices")
                }
                Button("Find Voice Models…") { finder = true }
                LabeledContent("More Mac voices") {
                    Button("Open VoiceOver Utility") { post("api/open-voice-settings") }
                }
                Text("VoiceOver Utility → Speech → Voice → Customize. Pick Premium or Enhanced versions.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude (optional)") {
                if c["key_source"] as? String == "env" {
                    Text("Enabled through the ANTHROPIC_API_KEY environment variable.").font(.caption).foregroundStyle(.secondary)
                } else {
                    SecureField("Anthropic API key", text: $key, prompt: Text(c["claude"] as? Bool == true ? "Saved. Paste a new key to replace it" : "sk-ant-…"))
                    HStack {
                        Button("Save Key") {
                            put(["anthropic_api_key": key.trimmingCharacters(in: .whitespacesAndNewlines)])
                            key = ""
                        }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if c["key_source"] as? String == "settings" { Button("Remove Saved Key") { put(["anthropic_api_key": ""]) } }
                    }
                    Text("Enables “Analyze with Claude” for more accurate characters. Stored only on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .sheet(isPresented: $finder) { ModelFinder().environment(model) }
        .task {
            while !Task.isCancelled {
                await model.refreshConfig()
                try? await Task.sleep(for: .seconds(kokoro["state"] as? String == "downloading" || qwen["state"] as? String == "downloading" ? 1 : 5))
            }
        }
    }

    @ViewBuilder private func offer(_ which: String, _ status: [String: Any], _ text: String, button: String) -> some View {
        let bytes = status["bytes"] as? Double ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text(text + " One-time download of \(bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : "\(Int(bytes / 1e6)) MB").").font(.callout).foregroundStyle(.secondary)
            Button(status["state"] as? String == "downloading" ? "Downloading…" : button) { post("api/\(which)/install") }
                .disabled(status["state"] as? String == "downloading")
            if status["state"] as? String == "downloading" || status["state"] as? String == "error" {
                Text(status["message"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func post(_ path: String) {
        guard let api = model.api else { return }
        Task {
            do { try await api.data(path, method: "POST") } catch { problem = error.localizedDescription }
            await model.refreshConfig()
        }
    }

    private func put(_ patch: [String: Any]) {
        guard let api = model.api else { return }
        Task {
            do {
                model.config = try await api.object("api/settings", method: "PUT", json: patch)
                problem = nil
                await model.reader?.refreshBook()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Browse text-to-speech models on Hugging Face, to see whether something better is out.
struct ModelFinder: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    struct Found: Codable, Identifiable {
        var id: String
        var url: String
        var likes: Int
        var downloads: Int
        var mlx: Bool?
        var in_realbook: String?
        var features: [String]
        var licence: String
        var gated: Bool?
        var created: String?
    }
    @State private var q = ""
    @State private var sort = "trending"
    @State private var english = true
    @State private var macOnly = false
    @State private var results: [Found] = []
    @State private var problem: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find Voice Models").font(.headline)
            Text("New open speech models from Hugging Face. Good signs for RealBook: “Voice design” (voices from a description), “Runs on Mac”, and an open licence.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Search models, e.g. voice design", text: $q).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $sort) {
                    Text("Trending").tag("trending")
                    Text("Most liked").tag("likes")
                    Text("Most downloaded").tag("downloads")
                    Text("Newest").tag("new")
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                Toggle("English", isOn: $english)
                Toggle("Runs on Mac only", isOn: $macOnly)
                if loading { ProgressView().controlSize(.small) }
            }
            List(results.filter { !macOnly || $0.mlx == true || $0.in_realbook != nil }) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Link(m.id, destination: URL(string: m.url) ?? URL(string: "https://huggingface.co")!).font(.callout.weight(.medium))
                        Spacer()
                        Text("♥ \(m.likes) · ↓ \(m.downloads)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(badges(m)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .task(id: "\(q)|\(sort)|\(english)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let api = model.api else { return }
            loading = true
            defer { loading = false }
            do {
                results = try await api.get([Found].self, "api/models/search", query: ["q": q, "sort": sort, "english": english ? "true" : "false"])
                problem = nil
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
    }

    private func badges(_ m: Found) -> String {
        var out = m.features + [m.licence]
        if let used = m.in_realbook { out.insert("In RealBook (\(used))", at: 0) }
        if m.mlx == true { out.insert("Runs on Mac", at: 0) }
        if m.gated == true { out.append("Gated") }
        return out.joined(separator: " · ")
    }
}
