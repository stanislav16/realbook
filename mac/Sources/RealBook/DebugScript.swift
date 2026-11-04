#if DEBUG
import AppKit
import SwiftUI

/// While developing: REALBOOK_SCRIPT="wait 3,open <id>,snap /tmp/a.png,..." drives the app, silently.
@MainActor
enum DebugScript {
    static var silent: Bool { ProcessInfo.processInfo.environment["REALBOOK_SCRIPT"] != nil }

    static func run(_ model: AppModel) async {
        guard let script = ProcessInfo.processInfo.environment["REALBOOK_SCRIPT"] else { return }
        for raw in script.split(separator: ",") {
            let step = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            let arg = step.count > 1 ? step[1] : ""
            switch step.first {
            case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "open": model.open(arg)
            case "library": model.closeBook()
            case "filter": model.filter = AppModel.Filter.allCases.first { $0.rawValue == arg } ?? .all
            case "text": model.look.showText = arg != "off"
            case "theme": model.look.theme = arg
            case "play": model.reader?.play()
            case "pause": model.reader?.pause()
            case "next": model.reader?.step(1)
            case "prev": model.reader?.step(-1)
            case "chapter": model.reader.map { r in r.goTo(chapter: arg == "next" ? r.chapter + 1 : Int(arg) ?? 0) }
            case "panel": NotificationCenter.default.post(name: .togglePanel, object: arg)
            case "away": model.reader?.following = false
            case "state": print("[state]", model.reader.map { "ch \($0.chapter) line \($0.segment)/\($0.segments.count) playing \($0.playing) loading \($0.loading) problem \($0.problem ?? "-")" } ?? "no book", "books", model.books.count, "filter", model.filter.rawValue)
            case "snap":
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let view = window.contentView else { print("[snap] no window"); continue }
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                print("[snap]", arg, window.frame.size)
            case "space":
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
                if let e { NSApp.postEvent(e, atStart: false) }
            case "responder": print("[responder]", NSApp.keyWindow.map { String(describing: type(of: $0.firstResponder as Any)) } ?? "no key window")
            case "activate": NSApp.activate(ignoringOtherApps: true)
            case "quit": NSApp.terminate(nil)
            default: print("[script] unknown", raw)
            }
            fflush(stdout)
        }
    }
}
#endif
