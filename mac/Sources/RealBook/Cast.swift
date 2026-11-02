import AVFoundation
import SwiftUI

/// A character or the narrator, with everything the Cast shows and changes.
struct Person: Codable, Identifiable, Equatable {
    var id: String = "narrator"
    var name: String = "Narrator"
    var gender: String?
    var age: String?
    var accent: String?
    var summary: String?
    var lines: Int?
    var evidence: [String]?
    var aliases: [String]?
    var other_names: [String]?
    var not_person: Bool?
    var voice: String
    var rate: Int?
    var pitch_shift: Int?
    var locked: Bool?
    var designed_from: String?
    var voice_description: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, gender, age, accent, summary, lines, evidence, aliases, other_names, not_person, voice, rate, pitch_shift, locked, designed_from, voice_description
    }

    init(from decoder: Decoder) throws {  // the narrator has no id or name of its own
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "narrator"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Narrator"
        gender = try c.decodeIfPresent(String.self, forKey: .gender)
        age = try c.decodeIfPresent(String.self, forKey: .age)
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        lines = try c.decodeIfPresent(Int.self, forKey: .lines)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
        other_names = try c.decodeIfPresent([String].self, forKey: .other_names)
        not_person = try c.decodeIfPresent(Bool.self, forKey: .not_person)
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        rate = try c.decodeIfPresent(Int.self, forKey: .rate)
        pitch_shift = try c.decodeIfPresent(Int.self, forKey: .pitch_shift)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        designed_from = try c.decodeIfPresent(String.self, forKey: .designed_from)
        voice_description = try c.decodeIfPresent(String.self, forKey: .voice_description)
    }

    var searchText: String { ([name] + (aliases ?? []) + (other_names ?? [])).joined(separator: " ").lowercased() }
    var designed: Bool { voice.hasPrefix("qwen:") }
}

struct CastDetails: Codable {
    struct Job: Codable, Equatable { var state: String?; var message: String? }
    var narrator: Person
    var cast: [Person]
    var pronunciations: [String: String]?
    var ai_done: [String: Double]?
    var job: Job?
}

struct VoiceOption: Codable, Identifiable {
    var name: String
    var base: String?
    var locale: String?
    var engine: String?
    var gender: String?
    var age: String?
    var blend: Bool?
    var grade: Double?
    var quality: Double?
    var id: String { name }

    private static let accents = ["en_US": "American", "en_GB": "British", "en_IE": "Irish", "en_AU": "Australian", "en_IN": "Indian", "en_ZA": "South African", "en-scotland": "Scottish"]
    var group: String {
        let place = Self.accents[locale ?? ""] ?? locale ?? ""
        if engine == "kokoro" { return blend == true ? "Natural · blends of two voices" : "Natural · \(place)" }
        return "Mac · \(place)"
    }
    var label: String {
        let stars = engine == "kokoro" ? ((grade ?? 0) >= 7 ? " ★" : "") : (quality ?? 0) >= 3 ? " ★★" : (quality ?? 0) == 2 ? " ★" : ""
        let who = (gender ?? "unknown") == "unknown" ? "" : " · \(gender!)\((age ?? "adult") != "adult" ? ", \(age!)" : "")"
        return "\(base ?? name)\(stars)\(who)"
    }
}

/// Plays a sample of a voice.
@MainActor
enum Sample {
    private static var player: AVAudioPlayer?

    static func play(_ person: Person, text: String, api: API) {
        Task {
            guard let data = try? await api.data("api/preview", query: ["voice": person.voice, "rate": String(person.rate ?? 180), "pitch_shift": String(person.pitch_shift ?? 0), "text": text]),
                  let audio = try? AVAudioPlayer(data: data) else { return }
            #if DEBUG
            if DebugScript.silent { audio.volume = 0 }
            #endif
            player = audio
            audio.play()
        }
    }
}

/// Who has which voice, floating at the right on the same glass as the player.
struct CastPanel: View {
    @Environment(AppModel.self) private var model
    let reader: Reader
    let close: () -> Void
    @State private var details: CastDetails?
    @State private var voices: [VoiceOption] = []
    @State private var search = ""
    @State private var sheet: CastSheet?
    @State private var removing: Person?
    @State private var confirm: Analysis?

    enum CastSheet: Identifiable {
        case rename(Person), merge(Person), new, pronunciations(String), export, importReview
        var id: String {
            switch self {
            case .rename(let p): "rename\(p.id)"
            case .merge(let p): "merge\(p.id)"
            case .new: "new"
            case .pronunciations(let w): "say\(w)"
            case .export: "export"
            case .importReview: "import"
            }
        }
    }

    struct Analysis: Identifiable {
        var engine: String
        var title: String
        var message: String
        var id: String { engine }
    }

    private var api: API { reader.api }
    private var busy: Bool { details?.job?.state == "running" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Cast").font(.headline)
                Spacer()
                menu
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26) }
                    .buttonStyle(GlassButton()).help("Close (esc)")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            TextField("Search characters", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 8)
            if let job = details?.job {
                HStack(spacing: 8) {
                    if job.state == "running" { ProgressView().controlSize(.small) }
                    Text(job.message ?? "").font(.caption).foregroundStyle(job.state == "error" ? .red : .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let d = details {
                        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
                        if q.isEmpty || "narrator".contains(q) { card(d.narrator, isNarrator: true) }
                        let shown = d.cast.filter { q.isEmpty || $0.searchText.contains(q) }
                        ForEach(shown) { card($0, isNarrator: false) }
                        if shown.isEmpty && !q.isEmpty && !"narrator".contains(q) { Text("No character called “\(q)”").foregroundStyle(.secondary) }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
        .task { await load() }
        .task(id: busy) { await watchJob() }
        .sheet(item: $sheet) { which in sheetView(which) }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let p = removing { Task { await drop(p, into: nil) } } }
        } message: {
            Text((removing?.lines ?? 0) > 0 ? "Their \(removing?.lines ?? 0) lines will be read by the narrator. To give them to another character instead, use Merge Into…" : "")
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Start") { if let a = confirm { Task { await start(a.engine) } } }
        } message: {
            Text(confirm?.message ?? "")
        }
    }

    private var menu: some View {
        let ai = model.config["local_ai"] as? [String: Any]
        let note = { (step: String) -> String in
            guard let t = details?.ai_done?[step] else { return "" }
            return " ✓ " + Date(timeIntervalSince1970: t).formatted(.dateTime.day().month())
        }
        return Menu {
            if ai?["supported"] as? Bool == true {
                Button("Describe Characters with Local AI…\(note("describe"))") {
                    confirm = Analysis(engine: "local", title: "Describe characters with local AI", message: "A small AI model on this Mac (\(ai?["label"] as? String ?? "")) reads what the book says about each of the main characters and decides their gender, age, accent and how they sound. Free and offline; it takes a few minutes.")
                }.disabled(busy)
                Button("Find Speakers with Local AI…\(note("speakers"))") {
                    confirm = Analysis(engine: "local-speakers", title: "Find speakers with local AI", message: "The AI model on this Mac (\(ai?["label"] as? String ?? "")) reads each scene and decides who speaks the lines that have no speech tag, where RealBook otherwise just guesses that speakers take turns. Lines with a tag and lines you fixed by hand are kept.")
                }.disabled(busy)
                Divider()
            }
            Button("Export for AI Review…") { sheet = .export }.disabled(busy)
            Button("Import AI Review…\(note("review"))") { sheet = .importReview }.disabled(busy)
            Button(model.config["claude"] as? Bool == true ? "Analyze with Claude…" : "Analyze with Claude (add a key in Settings)") {
                confirm = Analysis(engine: "claude", title: "Analyze with Claude", message: "Claude will read the whole book to describe each character and decide who says every line. This uses your Anthropic API credits (roughly $1–3 for a full novel). Speakers you fixed by hand will be kept.")
            }.disabled(busy || model.config["claude"] as? Bool != true)
            Divider()
            Button("Add Character…") { sheet = .new }
            Button("Pronunciations…") { sheet = .pronunciations("") }
        } label: {
            Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Circle())
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GlassButton()).fixedSize()
    }

    private func card(_ p: Person, isNarrator: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(isNarrator ? Color.secondary : Color(nsColor: NSColor(hex: reader.colors[p.id] ?? "#888888"))).frame(width: 9, height: 9)
                Text(p.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if !isNarrator {
                    Text("\(p.lines ?? 0) line\(p.lines == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("Rename…") { sheet = .rename(p) }
                        Button("Merge Into…") { sheet = .merge(p) }
                        Button("Pronunciation…") { sheet = .pronunciations(Self.pronounceable(p.name)) }
                        Divider()
                        Button("Remove", role: .destructive) { removing = p }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Circle())
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GlassButton()).fixedSize()
                }
            }
            summary(p, isNarrator: isNarrator)
            if let evidence = p.evidence, !evidence.isEmpty {
                DisclosureGroup("What the book says") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(evidence, id: \.self) { Text($0).font(.caption.italic()).foregroundStyle(.secondary) }
                    }
                }
                .font(.caption)
            }
            VoiceControls(person: p, who: p.id, voices: voices, text: isNarrator ? "" : sampleLine(p.id), reader: reader, designing: designing) { await load() }
            if p.locked == true { Text("Voice kept by you: updates and re-casts won't change it.").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func summary(_ p: Person, isNarrator: Bool) -> some View {
        if isNarrator {
            Text("Reads everything outside quotation marks").font(.caption).foregroundStyle(.secondary)
        } else {
            let meta = [p.gender == "unknown" ? nil : p.gender, p.age == "adult" ? nil : p.age, p.accent.flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "_", with: " ") }].compactMap { $0 }.joined(separator: " · ")
            let text = (p.summary?.isEmpty == false && p.summary != meta) ? p.summary! : (meta.isEmpty ? "no description found" : meta)
            Text(text + (p.not_person == true ? " · probably not a person" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }
    }

    private var designing: Bool {
        let engine = model.config["voice_engine"] as? String ?? ""
        return engine == "qwen" && (model.config["qwen"] as? [String: Any])?["installed"] as? Bool == true
    }

    private func sampleLine(_ id: String) -> String {
        reader.segments.first { $0.kind == "dialogue" && $0.speaker == id && $0.text.count > 25 }?.text ?? ""
    }

    private static func pronounceable(_ name: String) -> String {
        let titles: Set<String> = ["The", "Lady", "Duke", "Baron", "Dr.", "Reverend", "Mother", "Princess", "Emperor"]
        return name.split(separator: " ").map(String.init).first { $0.first?.isUppercase == true && !titles.contains($0) } ?? ""
    }

    @ViewBuilder private func sheetView(_ which: CastSheet) -> some View {
        let done = {
            sheet = nil
            Task {
                await load()
                await reader.refreshBook()
            }
        }
        switch which {
        case .rename(let p): RenameSheet(person: p, api: api, book: reader.id, done: done)
        case .merge(let p): MergeSheet(person: p, others: details?.cast.filter { $0.id != p.id } ?? []) { into in
            sheet = nil
            Task { await drop(p, into: into) }
        }
        case .new: NewCharacterSheet(api: api, book: reader.id, done: { _ in done() })
        case .pronunciations(let word): PronunciationsSheet(reader: reader, details: details, word: word, done: done)
        case .export: ReviewExportSheet(reader: reader) { sheet = nil }
        case .importReview: ReviewImportSheet(reader: reader, done: done)
        }
    }

    private func load() async {
        do {
            details = try await api.get(CastDetails.self, "api/books/\(reader.id)")
        } catch {
            reader.problem = "Couldn't read the cast: \(error)"
        }
        if voices.isEmpty, let v = try? await api.get([VoiceOption].self, "api/voices") { voices = v }
    }

    private func start(_ engine: String) async {
        do {
            try await api.data("api/books/\(reader.id)/analyze", method: "POST", json: ["engine": engine])
            await load()
        } catch {
            reader.problem = error.localizedDescription
        }
    }

    private func watchJob() async {
        guard busy else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            await load()
            if !busy {
                if details?.job?.state == "done" {
                    await model.refreshConfig()
                    await reader.refreshBook()
                    await reader.reloadChapter()
                    model.say(details?.job?.message ?? "Done")
                }
                return
            }
        }
    }

    private func drop(_ p: Person, into: String?) async {
        do {
            try await api.data("api/books/\(reader.id)/characters/\(p.id)", method: "DELETE", query: into.map { ["into": $0] } ?? [:])
            await load()
            await reader.refreshBook()
            await reader.reloadChapter()
            model.say(into == nil ? "Removed \(p.name)" : "Merged into \(details?.cast.first { $0.id == into }?.name ?? "")")
        } catch {
            reader.problem = error.localizedDescription
        }
    }
}

/// The voice of one person: pick it, hear it, describe it, keep it.
struct VoiceControls: View {
    @Environment(AppModel.self) private var model
    let person: Person
    let who: String
    let voices: [VoiceOption]
    let text: String
    let reader: Reader
    let designing: Bool
    let changed: () async -> Void
    @State private var description = ""
    @State private var pitch = 0.0
    @State private var rate = 180.0

    private var api: API { reader.api }
    private var groups: [(String, [VoiceOption])] {
        Dictionary(grouping: voices, by: \.group).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Voice", selection: Binding(get: { person.voice }, set: pick)) {
                    if person.designed {
                        Text("Designed voice").tag(person.voice)
                    } else if designing {
                        Text("Designed voice (from description)").tag("designed")
                    }
                    if !person.designed && !voices.contains(where: { $0.name == person.voice }) {
                        Text("\(person.voice.replacingOccurrences(of: "kokoro:", with: "")) (not available)").tag(person.voice)
                    }
                    ForEach(groups, id: \.0) { group in
                        Section(group.0) { ForEach(group.1) { Text($0.label).tag($0.name) } }
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Button { Sample.play(person, text: text, api: api) } label: { Image(systemName: "play.fill").font(.system(size: 10)) }
                    .controlSize(.small).help("Hear this voice")
            }
            if designing {
                Text(person.voice_description != nil ? "Your description (used instead of the book's)" : "Voice description, from the book").font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .font(.caption)
                    .scrollContentBackground(.hidden)
                    .frame(height: 54)
                    .padding(4)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 4) {
                    Button("Use Description") { design(["description": description]) }.help("Design a voice from this description")
                    Button("New Take") { design(["new_take": true]) }.help("Same description, a different voice")
                    if person.voice_description != nil { Button("Reset") { design(["description": ""]) }.help("Go back to the description written from the book") }
                    if person.locked == true {
                        Button("Unpin Voice") { design([:]) }.help("Let this character's voice follow the book again (it may change)")
                    } else {
                        Button("Keep Voice") { keep() }.help("Keep exactly this voice: new descriptions, re-casts and updates won't replace it")
                    }
                }
                .controlSize(.small)
            }
            if !person.designed {
                sliderRow("Pitch", value: $pitch, in: -20...20, label: (pitch > 0 ? "+" : "") + String(Int(pitch))) { save(pitch: Int(pitch)) }
                sliderRow("Speed", value: $rate, in: 110...280, label: String(Int(rate))) { save(rate: Int(rate)) }
            }
        }
        .onAppear(perform: sync)
        .onChange(of: person) { _, _ in sync() }
    }

    private func sync() {
        description = person.designed_from ?? ""
        pitch = Double(person.pitch_shift ?? 0)
        rate = Double(person.rate ?? 180)
    }

    private func sliderRow(_ name: String, value: Binding<Double>, in range: ClosedRange<Double>, label: String, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption).frame(width: 36, alignment: .leading)
            Slider(value: value, in: range) { editing in if !editing { commit() } }.controlSize(.mini)
            Text(label).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
        }
    }

    private var path: String { who == "narrator" ? "api/books/\(reader.id)/narrator" : "api/books/\(reader.id)/characters/\(who)" }

    private func pick(_ voice: String) {
        if voice == "designed" { design([:]) } else { save(voice: voice) }
    }

    private func save(voice: String? = nil, rate: Int? = nil, pitch: Int? = nil) {
        var next = person
        next.voice = voice ?? person.voice
        next.rate = rate ?? person.rate ?? 180
        next.pitch_shift = pitch ?? person.pitch_shift ?? 0
        Task {
            do {
                try await api.data(path, method: "PUT", json: ["voice": next.voice, "rate": next.rate ?? 180, "pitch_shift": next.pitch_shift ?? 0])
                await changed()
                await reader.refreshBook()
                Sample.play(next, text: text, api: api)
            } catch {
                reader.problem = error.localizedDescription
            }
        }
    }

    private func keep() {
        Task {
            do {
                try await api.data(path, method: "PUT", json: ["voice": person.voice, "rate": person.rate ?? 180, "pitch_shift": person.pitch_shift ?? 0])
                await changed()
                model.say("Voice kept. Updates and re-runs won't change it")
            } catch {
                reader.problem = error.localizedDescription
            }
        }
    }

    private func design(_ body: [String: Any]) {
        Task {
            do {
                let d = try await api.data("api/books/\(reader.id)/design/\(who)", method: "PUT", json: body)
                let updated = try JSONDecoder().decode(Person.self, from: d)
                await changed()
                await reader.refreshBook()
                model.say("Designing the voice. You'll hear it in a few seconds")
                Sample.play(updated, text: text, api: api)
            } catch {
                reader.problem = error.localizedDescription
            }
        }
    }
}

struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let person: Person
    let api: API
    let book: String
    let done: () -> Void
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(person.name)”").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            let others = Array(Set((person.other_names ?? []) + (person.aliases ?? []))).filter { $0 != person.name }.prefix(6)
            if !others.isEmpty { Text("The book also calls them: \(others.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    Task {
                        do {
                            try await api.data("api/books/\(book)/characters/\(person.id)", method: "PATCH", json: ["name": name])
                            done()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == person.name)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { name = person.name }
    }
}

struct MergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let person: Person
    let others: [Person]
    let merge: (String) -> Void
    @State private var into = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge “\(person.name)” into…").font(.headline)
            Text("For when two entries are the same person. Their lines move to the character you choose, and “\(person.name)” is removed.").font(.callout).foregroundStyle(.secondary)
            Picker("Same person as", selection: $into) {
                ForEach(others.sorted { ($0.lines ?? 0) > ($1.lines ?? 0) }) { Text("\($0.name) (\($0.lines ?? 0) lines)").tag($0.id) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") { merge(into) }.keyboardShortcut(.defaultAction).disabled(into.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { into = others.sorted { ($0.lines ?? 0) > ($1.lines ?? 0) }.first?.id ?? "" }
    }
}

struct NewCharacterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let api: API
    let book: String
    let done: (String?) -> Void
    @State private var name = ""
    @State private var gender = "unknown"
    @State private var age = "adult"
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Character").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Gender", selection: $gender) {
                    Text("Female").tag("female")
                    Text("Male").tag("male")
                    Text("Not sure").tag("unknown")
                }
                Picker("Age", selection: $age) {
                    Text("Child").tag("child")
                    Text("Young").tag("young")
                    Text("Adult").tag("adult")
                    Text("Old").tag("old")
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        do {
                            let r = try await api.object("api/books/\(book)/characters", method: "POST", json: ["name": name, "gender": gender, "age": age])
                            done(r["id"] as? String)
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
    }
}

/// How the voices should say unusual names.
struct PronunciationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    struct Row: Identifiable { let id = UUID(); var word: String; var say: String }
    let reader: Reader
    let details: CastDetails?
    let word: String
    let done: () -> Void
    @State private var rows: [Row] = []
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pronunciations").font(.headline)
            Text("Voices guess at unusual names and can say them differently each time. Spell a name the way it should sound, and every voice will say it that way.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($rows) { $row in
                        HStack(spacing: 6) {
                            TextField("As written", text: $row.word).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            TextField("Say it like", text: $row.say).textFieldStyle(.roundedBorder)
                            Button { listen(row) } label: { Image(systemName: "play.fill").font(.system(size: 10)) }.help("Listen")
                            Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "xmark").font(.system(size: 10)) }.help("Remove")
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            Button("Add Name") { rows.append(Row(word: "", say: "")) }
            Text("Use ordinary spelling, like “Peter” for Piter. ▶ plays it with the voice of whoever has that name.").font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear {
            rows = (details?.pronunciations ?? [:]).sorted { $0.key < $1.key }.map { Row(word: $0.key, say: $0.value) }
            if !word.isEmpty, !(details?.pronunciations ?? [:]).keys.contains(word) { rows.append(Row(word: word, say: "")) }
            if rows.isEmpty { rows.append(Row(word: "", say: "")) }
        }
    }

    private func listen(_ row: Row) {
        guard let details, !row.say.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let w = row.word.trimmingCharacters(in: .whitespaces)
        let p = details.cast.first { ([$0.name] + ($0.aliases ?? [])).contains { $0.split(separator: " ").map(String.init).contains(w) } } ?? details.narrator
        Sample.play(p, text: row.say.trimmingCharacters(in: .whitespaces) + ".", api: reader.api)
    }

    private func save() {
        var words: [String: String] = [:]
        for row in rows {
            let w = row.word.trimmingCharacters(in: .whitespaces), s = row.say.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty && !s.isEmpty { words[w] = s }
        }
        Task {
            do {
                try await reader.api.data("api/books/\(reader.id)/pronunciations", method: "PUT", json: ["words": words])
                await reader.reloadChapter()
                done()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct ReviewExportSheet: View {
    @Environment(AppModel.self) private var model
    let reader: Reader
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export for AI Review").font(.headline)
            Text("Have a stronger AI, like Claude, check who says each line and how each character should sound. RealBook makes a ZIP with the book split into parts, each with its own instructions.").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Unzip it, open a chat at claude.ai (or another strong AI) and drag in Part 1. No need to type anything; the file explains the task.")
                Text("2. The AI answers with a block of corrections. Copy its whole reply.")
                Text("3. Here: Cast → ••• → Import AI Review… → paste → Import.")
                Text("4. Repeat for each part, best in a new chat each time.")
            }
            .font(.callout)
            Text("Corrected lines are protected like lines you fix by hand; the local AI won't change them later.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save to Downloads") {
                    close()
                    Task {
                        do {
                            let r = try await reader.api.object("api/books/\(reader.id)/review/save", method: "POST")
                            let parts = r["parts"] as? Int ?? 0
                            model.say("Saved to Downloads (\(parts) part\(parts == 1 ? "" : "s"))", seconds: 5)
                        } catch {
                            model.say(error.localizedDescription, seconds: 6)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }
}

struct ReviewImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reader: Reader
    let done: () -> Void
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import AI Review").font(.headline)
            Text("Paste the reply from the AI chat for one part of this book's review, including the ```json block.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(height: 220).padding(4).background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    Task {
                        do {
                            let r = try await reader.api.object("api/books/\(reader.id)/review/import", method: "POST", json: ["text": text])
                            let parts: [(String, String)] = [("speakers", "speakers"), ("characters", "characters"), ("added", "new"), ("merged", "merged"), ("said", "pronunciations")]
                            let bits = parts.compactMap { key, name in (r[key] as? Int).flatMap { $0 > 0 ? "\($0) \(name)" : nil } }
                            let skipped = r["skipped_count"] as? Int ?? 0
                            model.say("Review imported: \(bits.isEmpty ? "nothing to change" : bits.joined(separator: ", "))\(skipped > 0 ? " (\(skipped) entries didn't match the book and were skipped)" : "")", seconds: 6)
                            await reader.refreshBook()
                            await reader.reloadChapter()
                            done()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 560)
    }
}
