import SwiftUI

@main
struct RealBookApp: App {
    @State private var library = Library()
    @State private var player = Player()
    @State private var look = Look()
    @State private var lookAsked = false
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
                .environment(look)
                .task { await syncNow() }
                .onChange(of: phase) { _, now in
                    if now == .active { Task { await syncNow() } }
                }
        }
    }

    private func syncNow() async {
        let moved = await library.sync()
        for id in moved {
            if let b = library.book(id) { player.follow(b) }
        }
        if library.reachable && !lookAsked, let mac = try? await library.mac.appearance() {
            lookAsked = true
            look.adopt(mac: mac)  // the Mac's reading look, until one is picked here
        }
    }
}
