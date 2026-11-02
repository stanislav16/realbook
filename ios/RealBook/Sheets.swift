import SwiftUI
import UIKit

struct Banner: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)) }.buttonStyle(.plain)
        }
        .font(.footnote)
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The Mac's Aa menu: text size, theme, font, justification and coloured dialogue.
struct AppearanceSheet: View {
    @Environment(Look.self) private var look

    var body: some View {
        @Bindable var look = look
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                Button { look.size = max(0, look.size - 1) } label: { Text("A").font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44) }
                Divider().frame(height: 24)
                Button { look.size = min(Look.sizes.count - 1, look.size + 1) } label: { Text("A").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 44) }
            }
            .buttonStyle(.plain)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 10) {
                ForEach(Look.themes) { t in
                    Button { look.theme = t.id } label: {
                        VStack(spacing: 6) {
                            Text("Aa").font(.system(size: 17, weight: .medium, design: .serif))
                                .frame(width: 52, height: 52)
                                .foregroundStyle(t.id == "original" ? Color.gray : Color(t.ink))
                                .background {
                                    if t.id == "original" {
                                        LinearGradient(stops: [.init(color: .white, location: 0.5), .init(color: .black, location: 0.5)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                    } else {
                                        Color(t.background)
                                    }
                                }
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(look.theme == t.id ? Color.accentColor : Color.primary.opacity(0.15),
                                                               lineWidth: look.theme == t.id ? 2.5 : 0.5))
                            Text(t.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Font")
                    Spacer()
                    Picker("Font", selection: $look.font) {
                        ForEach(Look.fonts, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, 2)
                Divider()
                Toggle("Justify text", isOn: $look.justify).padding(.vertical, 8)
                Divider()
                Toggle("Colour dialogue by character", isOn: $look.colorDialogue).padding(.vertical, 8)
            }
            .padding(.horizontal, 14)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(20)
        .tint(.accentColor)
    }
}

/// Who has a voice in the book, as in the Mac's Cast panel, with a sample of each voice.
struct CastSheet: View {
    @Environment(Player.self) private var player
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(player.cast.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { m in
                        CastRow(member: m)
                            .listRowBackground(Color.clear)
                    }
                } footer: {
                    Text("Change voices, rename characters and re-cast in RealBook on your Mac. Hold a line on the page to change who says it.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Cast")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search characters")
        }
    }
}

struct CastRow: View {
    @Environment(Player.self) private var player
    let member: CastMember

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(member.color.map { Color(UIColor(hex: $0)) } ?? Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(member.name).font(.body.weight(.semibold))
                    Spacer()
                    if let n = member.lines, n > 0 {
                        Text("\(n) line\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = member.summary, !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                if let voice = member.voice, !voice.isEmpty {
                    Text(voice).font(.footnote).italic().foregroundStyle(.secondary).lineLimit(3)
                }
            }
            if member.sample != nil {
                Button { player.sample(member) } label: {
                    Group {
                        if player.sampling == member.id {
                            Image(systemName: "stop.circle.fill")
                        } else {
                            Image(systemName: "play.circle")
                        }
                    }
                    .font(.title2)
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hear \(member.name)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Who says this?": gives a quote to someone else in the cast, on the Mac.
struct SpeakerPicker: View {
    @Environment(Player.self) private var player
    let segment: Int
    let close: () -> Void
    @State private var search = ""
    @State private var saving = false

    var body: some View {
        let line = player.page.first { $0.segment == segment }
        NavigationStack {
            List {
                if let line {
                    Section {
                        Text("“\(line.text)”").font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary).lineLimit(4)
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(player.cast.filter { !$0.id.isEmpty && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { m in
                        row(m.name, color: m.color, chosen: line?.speaker == m.id) { choose(m.id) }
                            .listRowBackground(Color.clear)
                    }
                    if search.isEmpty {
                        row("Unknown (narrator reads it)", color: nil, chosen: line?.speaker == nil) { choose(nil) }
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Who Says This?")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search characters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                if saving { ToolbarItem(placement: .confirmationAction) { ProgressView() } }
            }
            .disabled(saving)
        }
    }

    private func row(_ name: String, color: String?, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(color.map { Color(UIColor(hex: $0)) } ?? Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
                Text(name).foregroundStyle(.primary)
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
        }
    }

    private func choose(_ speaker: String?) {
        saving = true
        Task {
            await player.setSpeaker(speaker, segment: segment)
            close()
        }
    }
}

/// How long this book can be listened to without the Mac, shown from the player's top bar.
struct OfflineTime: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var bytes: Int64 = 0

    var body: some View {
        let minutes = player.savedMinutes ?? 0
        let planned = max(minutes, player.plannedMinutes)
        VStack(alignment: .leading, spacing: 10) {
            Text("OFFLINE LISTENING").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(Kept.duration(minutes: minutes)).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(player.speed == 1 ? "saved ahead on this iPhone" : "saved ahead on this iPhone, at \(PlayerScreen.speedLabel(player.speed))")
                .font(.footnote).foregroundStyle(.secondary)
            if planned > 0 {
                ProgressView(value: Double(minutes), total: Double(planned))
                Text("of \(Kept.duration(minutes: planned)) to be saved").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Label(state, systemImage: library.reachable ? "laptopcomputer" : "laptopcomputer.slash")
                .font(.footnote).fixedSize(horizontal: false, vertical: true)
            if bytes > 0 {
                Label(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " on this iPhone", systemImage: "internaldrive")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .task(id: minutes) {
            if let id = player.bookID { bytes = library.kept.bytes(of: id) }
        }
    }

    private var state: String {
        guard let id = player.bookID else { return "" }
        guard library.reachable else { return "Your Mac isn't near. More is saved when you're back." }
        let making = library.kept.making(id)
        if making?.enabled == false { return "Turned off in Listen on iPhone on your Mac." }
        switch making?.state {
        case "battery": return "Plug in your Mac to make more."
        case "making": return "Your Mac is making more: \(making?.done ?? 0) of \(making?.total ?? 0) lines."
        case "error": return "Your Mac couldn't make some lines. It tries again soon."
        default: return library.kept.saving == id ? "Saving to this iPhone…" : "Everything your Mac made is saved."
        }
    }
}
