import SwiftUI

/// A book playing: only its cover, or (Text) the whole chapter. The same player over both, real glass,
/// with Chapters and Cast floating on the same glass at the sides.
struct ReaderScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme
    let reader: Reader
    @State private var panel: Panel?
    @State private var showLook = false
    @State private var scrubbing: Double?
    @State private var cover: NSImage?
    @State private var panelHeight: CGFloat = 104
    @State private var who: WhoRequest?
    @State private var exporting = false
    @State private var waiting = false

    enum Panel: String { case toc, cast }
    struct WhoRequest: Identifiable { var id: Int }

    private var look: Look { model.look }
    private var showText: Bool { look.showText }
    private var scheme: ColorScheme { showText ? (look.scheme ?? systemScheme) : .dark }
    private var pageColor: Color { showText ? Color(nsColor: look.current.background) : .black }
    private var ink: Color { showText ? Color(nsColor: look.current.ink) : .white }
    private var muted: Color { showText ? Color(nsColor: look.current.muted) : .white.opacity(0.6) }

    var body: some View {
        ZStack(alignment: .bottom) {
            background
            if showText {
                page
            } else {
                coverView
            }
            if showText && !reader.following {
                Button { reader.following = true } label: {
                    Label("Line Being Read", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glass(in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, panelHeight + 26)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Moves over for a side panel, into the room that's left.
            playerBar.padding(.bottom, 14).offset(x: panel == .toc ? 160 : panel == .cast ? -190 : 0)
            HStack(spacing: 0) {
                if panel == .toc {
                    ChaptersPanel(reader: reader) { panel = nil }.transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if panel == .cast {
                    CastPanel(reader: reader) { panel = nil }.transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .foregroundStyle(ink)
        .tint(ink)
        .environment(\.colorScheme, scheme)
        .animation(.easeInOut(duration: 0.22), value: panel)
        .animation(.easeInOut(duration: 0.25), value: showText)
        .animation(.easeOut(duration: 0.2), value: reader.following)
        .toolbar { toolbar }
        .navigationTitle(showText ? (reader.book?.title ?? "") : "")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task(id: reader.id) { await loadCover() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePanel)) { note in
            let wanted = Panel(rawValue: note.object as? String ?? "")
            panel = panel == wanted ? nil : wanted
        }
        .onAppear {
            if model.exportOnOpen {
                model.exportOnOpen = false
                exporting = true
            }
        }
        .sheet(item: $who) { request in SpeakerPicker(reader: reader, line: request.id) }
        .onExitCommand { panel = nil }
        .sheet(isPresented: $exporting) { ExportSheet(reader: reader) }
        .alert("RealBook", isPresented: Binding(get: { reader.problem != nil }, set: { if !$0 { reader.problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(reader.problem ?? "")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Library", systemImage: "chevron.left") { model.closeBook() }
                .labelStyle(.titleAndIcon)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Read This Line Again", systemImage: "arrow.counterclockwise") { Task { await reader.readAgain(reader.segment) } }
                    .disabled(reader.segments.isEmpty)
                Divider()
                Button("Cast", systemImage: "person.2") { panel = panel == .cast ? nil : .cast }
                Button("Text Size & Theme…", systemImage: "textformat.size") { showLook = true }
                if model.canExport {
                    Divider()
                    Button("Export Audiobook…", systemImage: "square.and.arrow.up") { exporting = true }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .popover(isPresented: $showLook, arrowEdge: .bottom) { LookPopover().environment(model) }
        }
    }

    @ViewBuilder private var background: some View {
        if showText {
            pageColor.ignoresSafeArea()
        } else {
            Color.black
                .overlay {
                    if let cover {
                        Image(nsImage: cover).resizable().scaledToFill().blur(radius: 60).saturation(1.3).opacity(0.55)
                    }
                }
                .overlay(LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.7), .black], startPoint: .top, endPoint: .bottom))
                .clipped()
                .ignoresSafeArea()
        }
    }

    private var page: some View {
        ZStack(alignment: .bottom) {
            ChapterPage(reader: reader, look: look, bottomInset: panelHeight + 70, dark: scheme == .dark) { line, _, _ in
                who = WhoRequest(id: line)
            }
            // The text fades on its way under the glass, so only a hint of it shows through.
            LinearGradient(stops: [.init(color: pageColor.opacity(0), location: 0),
                                   .init(color: pageColor.opacity(0.82), location: 60 / (panelHeight + 74)),
                                   .init(color: pageColor.opacity(0.97), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: panelHeight + 74)
                .allowsHitTesting(false)
        }
    }

    private var coverView: some View {
        VStack(spacing: 0) {
            Group {
                if let cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
                } else {
                    GeneratedCover(title: reader.book?.title ?? "", author: reader.book?.author ?? "").aspectRatio(2 / 3, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 30, y: 22)
            .frame(maxWidth: 680, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                look.showText = true
                look.changed()
            }
            VStack(spacing: 2) {
                Text(reader.book?.title ?? "").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(reader.chapterLabel).font(.callout).foregroundStyle(muted).lineLimit(1)
            }
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 32)
        .padding(.top, 4)
        .padding(.bottom, panelHeight + 18)
    }

    // MARK: - player

    private var playerBar: some View {
        let lines = reader.segments.count
        let at = scrubbing.map { Int($0.rounded()) } ?? reader.segment
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { scrubbing ?? Double(reader.segment) }, set: { scrubbing = $0 }), in: 0...Double(max(1, lines - 1))) { editing in
                if !editing, let s = scrubbing {
                    reader.go(to: Int(s.rounded()))
                    scrubbing = nil
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Line in this chapter")
            HStack {
                Text("Line \(at + 1) of \(lines)")
                Spacer()
                Text(reader.timeLeft(from: at))
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(muted)
            HStack(spacing: 4) {
                speedMenu
                sleepMenu
                Spacer(minLength: 8)
                icon("backward.end.fill", "Previous line (←)") { reader.step(-1) }
                playButton.padding(.horizontal, 8)
                icon("forward.end.fill", "Next line (→)") { reader.step(1) }
                Spacer(minLength: 8)
                icon("text.alignleft", "Show the text (⌘3)", on: showText) {
                    look.showText.toggle()
                    look.changed()
                }
                icon("list.bullet", "Chapters (⌘1)", on: panel == .toc) { panel = panel == .toc ? nil : .toc }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(width: 500)
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, now in panelHeight = now } })
    }

    private func icon(_ name: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 16)).frame(width: 38, height: 38)
        }
        .buttonStyle(GlassButton(on: on))
        .help(help)
        .accessibilityLabel(help)
    }

    private var playButton: some View {
        Button { reader.toggle() } label: {
            ZStack {
                Circle().fill(ink).frame(width: 46, height: 46)
                if waiting && reader.loading && reader.playing {
                    ProgressView().controlSize(.small).tint(pageColor)
                } else {
                    Image(systemName: reader.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(showText ? pageColor : .black)
                        .offset(x: reader.playing ? 0 : 1.5)
                }
            }
        }
        .buttonStyle(SolidPress())
        .help("Play / pause (space)")
        .accessibilityLabel(reader.playing ? "Pause" : "Play")
        .task(id: reader.loading && reader.playing) {
            waiting = false
            guard reader.loading && reader.playing else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { waiting = true }
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { reader.speed }, set: { reader.speed = $0 })) {
                ForEach(Reader.speeds, id: \.self) { Text(speedLabel($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(speedLabel(reader.speed)).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 38, height: 38)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GlassButton()).fixedSize()
        .help("Playback speed")
    }

    private var sleepMenu: some View {
        Menu {
            Picker("Sleep Timer", selection: Binding(get: { reader.sleep }, set: { reader.setSleep($0) })) {
                Text("Off").tag(Reader.Sleep.off)
                ForEach([5, 15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag(Reader.Sleep.minutes($0)) }
                Text("End of Chapter").tag(Reader.Sleep.endOfChapter)
            }
            .pickerStyle(.inline)
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Group {
                    if let ends = reader.sleepEnds {
                        let left = max(0, Int(ends.timeIntervalSinceNow))
                        Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    } else {
                        Image(systemName: reader.sleep == .off ? "moon" : "moon.fill").font(.system(size: 16))
                    }
                }
                .frame(width: 38, height: 38)
            }
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GlassButton(on: reader.sleep != .off)).fixedSize()
        .help("Stop playing after a while")
    }

    private func speedLabel(_ s: Float) -> String { s == 1 ? "1×" : String(format: "%g×", s) }

    private func loadCover() async {
        guard let api = model.api, let data = try? await api.data("api/books/\(reader.id)/cover") else { return }
        cover = NSImage(data: data)
    }
}

/// The big solid button: it answers at once, and doesn't turn to glass.
struct SolidPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }

    private struct Inner: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .opacity(hovering && !configuration.isPressed ? 0.88 : 1)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(configuration.isPressed ? nil : .spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
        }
    }
}

/// Text size, theme, font, justification and coloured dialogue.
struct LookPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var look = model.look
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                Button { change { $0.size = max(0, $0.size - 1) } } label: { Text("A").font(.system(size: 14, design: .serif)).frame(maxWidth: .infinity, minHeight: 34).contentShape(Rectangle()) }
                Divider().frame(height: 22)
                Button { change { $0.size = min(Look.sizes.count - 1, $0.size + 1) } } label: { Text("A").font(.system(size: 22, design: .serif)).frame(maxWidth: .infinity, minHeight: 34).contentShape(Rectangle()) }
            }
            .buttonStyle(.plain)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                ForEach(Look.themes(dark: look.systemDark)) { theme in
                    Button { change { $0.theme = theme.id } } label: {
                        VStack(spacing: 4) {
                            Text("Aa").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Color(nsColor: theme.ink))
                                .frame(width: 42, height: 42)
                                .background(Color(nsColor: theme.background), in: Circle())
                                .overlay(Circle().strokeBorder(look.theme == theme.id ? Color.accentColor : .secondary.opacity(0.4), lineWidth: look.theme == theme.id ? 2.5 : 0.5))
                            Text(theme.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Picker("Font", selection: Binding(get: { look.font }, set: { v in change { $0.font = v } })) {
                ForEach(Look.fonts, id: \.id) { Text($0.name).tag($0.id) }
            }
            Toggle("Justify text", isOn: Binding(get: { look.justify }, set: { v in change { $0.justify = v } }))
            Toggle("Colour dialogue by character", isOn: Binding(get: { look.colorDialogue }, set: { v in change { $0.colorDialogue = v } }))
        }
        .padding(16)
        .frame(width: 320)
    }

    private func change(_ edit: (Look) -> Void) {
        edit(model.look)
        model.look.changed()
    }
}

/// The book's chapters, in their parts, floating at the left.
struct ChaptersPanel: View {
    let reader: Reader
    let close: () -> Void

    private struct Part: Identifiable { var id: Int; var heading: String?; var headingChapter: Int?; var rows: [Int] }

    private var parts: [Part] {
        var parts: [Part] = []
        let toc = reader.book?.toc ?? []
        for (i, entry) in toc.enumerated() {
            let name = entry.section ?? ""
            if name.isEmpty {
                parts.append(Part(id: i, heading: nil, rows: [i]))
            } else if parts.last?.heading == name {
                parts[parts.count - 1].rows.append(i)
            } else if entry.title.lowercased() == name.lowercased() {
                parts.append(Part(id: i, heading: name, headingChapter: i, rows: []))  // a chapter named after its part is its heading
            } else {
                parts.append(Part(id: i, heading: name, rows: [i]))
            }
        }
        return parts
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chapters").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26) }
                    .buttonStyle(GlassButton()).help("Close (esc)")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(parts) { part in
                            Section {
                                ForEach(part.rows, id: \.self) { i in row(i, indent: part.heading != nil).id(i) }
                            } header: {
                                if let heading = part.heading { header(heading, chapter: part.headingChapter ?? part.rows.first ?? 0).id(part.headingChapter ?? -1 - part.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
                .onAppear { proxy.scrollTo(reader.chapter, anchor: .center) }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
    }

    private func header(_ text: String, chapter: Int) -> some View {
        Button { reader.goTo(chapter: chapter) } label: {
            Text(text).font(.callout.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
        }
        .buttonStyle(GlassButton(on: reader.chapter == chapter, circle: false))
        .background(.bar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ i: Int, indent: Bool) -> some View {
        Button { reader.goTo(chapter: i) } label: {
            Text(reader.chapterTitles[i])
                .font(.callout.weight(reader.chapter == i ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, indent ? 24 : 10).padding(.trailing, 10).padding(.vertical, 6)
        }
        .buttonStyle(GlassButton(on: reader.chapter == i, circle: false))
    }
}

/// Who says this line.
struct SpeakerPicker: View {
    @Environment(\.dismiss) private var dismiss
    let reader: Reader
    let line: Int
    @State private var search = ""
    @State private var creating = false

    var body: some View {
        let cast = (reader.book?.cast ?? []).filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
        VStack(spacing: 0) {
            TextField("Search characters", text: $search).textFieldStyle(.roundedBorder).padding(12)
            List {
                ForEach(cast, id: \.id) { member in
                    Button {
                        Task { await reader.setSpeaker(member.id, line: line) }
                        dismiss()
                    } label: {
                        HStack {
                            Circle().fill(Color(nsColor: NSColor(hex: reader.colors[member.id] ?? "#888888"))).frame(width: 9, height: 9)
                            Text(member.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task { await reader.setSpeaker(nil, line: line) }
                    dismiss()
                } label: { Text("Unknown (narrator reads it)").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                Button("New Character…") { creating = true }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
        }
        .frame(width: 340, height: 460)
        .sheet(isPresented: $creating) {
            NewCharacterSheet(api: reader.api, book: reader.id) { id in
                creating = false
                Task {
                    await reader.refreshBook()
                    if let id { await reader.setSpeaker(id, line: line) }
                    dismiss()
                }
            }
        }
    }
}
