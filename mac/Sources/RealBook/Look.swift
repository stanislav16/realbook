import AppKit
import Observation
import SwiftUI

/// How the reading page looks. Kept by the engine (the Aa menu), so the iPhone can start from it.
@MainActor
@Observable
final class Look {
    struct Theme: Identifiable {
        var id: String
        var name: String
        var background: NSColor
        var ink: NSColor
        var muted: NSColor
        var highlight: NSColor
        var dark: Bool?  // nil: follows the system
    }

    static func themes(dark: Bool) -> [Theme] { [
        Theme(id: "original", name: "Original", background: dark ? .black : .white, ink: NSColor(hex: dark ? "#e5e5e7" : "#1d1d1f"),
              muted: NSColor(hex: dark ? "#8e8e93" : "#86868b"), highlight: NSColor(white: dark ? 1 : 0, alpha: dark ? 0.11 : 0.07), dark: nil),
        Theme(id: "paper", name: "Paper", background: NSColor(hex: "#f3f0e8"), ink: NSColor(hex: "#2b2925"), muted: NSColor(hex: "#8c867a"),
              highlight: NSColor(srgbRed: 70 / 255, green: 50 / 255, blue: 20 / 255, alpha: 0.1), dark: false),
        Theme(id: "sepia", name: "Sepia", background: NSColor(hex: "#f1e4c9"), ink: NSColor(hex: "#3d2f1f"), muted: NSColor(hex: "#957d5c"),
              highlight: NSColor(srgbRed: 80 / 255, green: 50 / 255, blue: 15 / 255, alpha: 0.12), dark: false),
        Theme(id: "gray", name: "Gray", background: NSColor(hex: "#48484b"), ink: NSColor(hex: "#e0e0e0"), muted: NSColor(hex: "#a5a5aa"),
              highlight: NSColor(white: 1, alpha: 0.12), dark: true),
        Theme(id: "night", name: "Night", background: .black, ink: NSColor(hex: "#c8c8cc"), muted: NSColor(hex: "#7c7c80"),
              highlight: NSColor(white: 1, alpha: 0.1), dark: true),
    ] }

    static let fonts: [(id: String, name: String, family: String?)] = [
        ("newyork", "New York", nil), ("iowan", "Iowan", "Iowan Old Style"), ("palatino", "Palatino", "Palatino"),
        ("georgia", "Georgia", "Georgia"), ("charter", "Charter", "Charter"), ("sf", "San Francisco", ""),
    ]
    static let sizes: [CGFloat] = [14, 15, 16, 17, 18, 20, 22, 24, 27, 30]

    var theme = "original"
    var font = "newyork"
    var size = 5
    var justify = true
    var colorDialogue = true
    var showText = false
    var systemDark = false

    var onChange: (([String: Any]) -> Void)?

    var current: Theme { Self.themes(dark: systemDark).first { $0.id == theme } ?? Self.themes(dark: systemDark)[0] }
    /// The cover view is always dark; the text takes the theme.
    var pageIsDark: Bool { current.dark ?? systemDark }
    var scheme: ColorScheme? { current.dark.map { $0 ? .dark : .light } }

    func font(size pt: CGFloat? = nil) -> NSFont {
        let pt = pt ?? Self.sizes[max(0, min(size, Self.sizes.count - 1))]
        let base = NSFont.systemFont(ofSize: pt)
        switch Self.fonts.first(where: { $0.id == font })?.family {
        case nil: return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: pt) } ?? base
        case "": return base
        case let family?: return NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: pt) ?? base
        }
    }

    func apply(_ d: [String: Any]) {
        if let v = d["theme"] as? String { theme = v }
        if let v = d["font"] as? String { font = v }
        if let v = d["size"] as? Int { size = max(0, min(v, Self.sizes.count - 1)) }
        if let v = d["justify"] as? Bool { justify = v }
        if let v = d["colorDialogue"] as? Bool { colorDialogue = v }
        if let v = d["showText"] as? Bool { showText = v }
    }

    func changed() {
        onChange?(["theme": theme, "font": font, "size": size, "justify": justify, "colorDialogue": colorDialogue, "showText": showText])
    }
}
