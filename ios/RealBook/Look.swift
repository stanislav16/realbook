import Observation
import SwiftUI
import UIKit

/// How the reading page looks: the same themes, fonts and sizes as the Mac's Aa menu. Starts from
/// the Mac's choice, and is this iPhone's own once changed here.
@MainActor
@Observable
final class Look {
    struct Theme: Identifiable {
        var id: String
        var name: String
        var background: UIColor
        var ink: UIColor
        var muted: UIColor
        var highlight: UIColor
    }

    static let themes: [Theme] = [
        Theme(id: "original", name: "Original",
              background: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#1e1e1e") : .white },
              ink: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#e5e5e7") : UIColor(hex: "#1d1d1f") },
              muted: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#8e8e93") : UIColor(hex: "#86868b") },
              highlight: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.11) : UIColor(white: 0, alpha: 0.07) }),
        Theme(id: "paper", name: "Paper", background: UIColor(hex: "#f3f0e8"), ink: UIColor(hex: "#2b2925"),
              muted: UIColor(hex: "#8c867a"), highlight: UIColor(red: 70 / 255, green: 50 / 255, blue: 20 / 255, alpha: 0.1)),
        Theme(id: "sepia", name: "Sepia", background: UIColor(hex: "#f1e4c9"), ink: UIColor(hex: "#3d2f1f"),
              muted: UIColor(hex: "#957d5c"), highlight: UIColor(red: 80 / 255, green: 50 / 255, blue: 15 / 255, alpha: 0.12)),
        Theme(id: "gray", name: "Gray", background: UIColor(hex: "#48484b"), ink: UIColor(hex: "#e0e0e0"),
              muted: UIColor(hex: "#a5a5aa"), highlight: UIColor(white: 1, alpha: 0.12)),
        Theme(id: "night", name: "Night", background: .black, ink: UIColor(hex: "#c8c8cc"),
              muted: UIColor(hex: "#7c7c80"), highlight: UIColor(white: 1, alpha: 0.1)),
    ]

    /// id, name, and the font's family on iOS (nil: the system's serif, New York).
    static let fonts: [(id: String, name: String, family: String?)] = [
        ("newyork", "New York", nil), ("iowan", "Iowan", "Iowan Old Style"), ("palatino", "Palatino", "Palatino"),
        ("georgia", "Georgia", "Georgia"), ("charter", "Charter", "Charter"), ("sf", "San Francisco", ""),
    ]

    /// The Mac's sizes, less a step: a phone is read closer.
    static let sizes: [CGFloat] = [13, 14, 15, 16, 17, 18, 20, 22, 25, 28]

    var theme = "original" { didSet { save() } }
    var font = "newyork" { didSet { save() } }
    var size = 5 { didSet { save() } }
    var justify = true { didSet { save() } }
    var colorDialogue = true { didSet { save() } }

    private var loading = false

    init() {
        guard let saved = UserDefaults.standard.dictionary(forKey: "look") else { return }
        apply(saved)
    }

    var current: Theme { Self.themes.first { $0.id == theme } ?? Self.themes[0] }
    /// Dark page themes keep the bars and sheets dark too.
    var scheme: ColorScheme? { theme == "gray" || theme == "night" ? .dark : theme == "original" ? nil : .light }

    func uiFont(weight: UIFont.Weight = .regular) -> UIFont {
        let pt = Self.sizes[max(0, min(size, Self.sizes.count - 1))]
        let base = UIFont.systemFont(ofSize: pt, weight: weight)
        switch Self.fonts.first(where: { $0.id == font })?.family {
        case nil:
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: pt) } ?? base
        case "":
            return base
        case let family?:
            return UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: family]), size: pt)
        }
    }

    /// Takes the Mac's look, unless this iPhone has its own.
    func adopt(mac: [String: Any]) {
        guard UserDefaults.standard.dictionary(forKey: "look") == nil, !mac.isEmpty else { return }
        apply(mac)
        UserDefaults.standard.removeObject(forKey: "look")  // still the Mac's, until changed here
    }

    private func apply(_ d: [String: Any]) {
        loading = true
        defer { loading = false }
        if let v = d["theme"] as? String, Self.themes.contains(where: { $0.id == v }) { theme = v }
        if let v = d["font"] as? String, Self.fonts.contains(where: { $0.id == v }) { font = v }
        if let v = d["size"] as? Int { size = max(0, min(v, Self.sizes.count - 1)) }
        if let v = d["justify"] as? Bool { justify = v }
        if let v = d["colorDialogue"] as? Bool { colorDialogue = v }
    }

    private func save() {
        guard !loading else { return }
        UserDefaults.standard.set(["theme": theme, "font": font, "size": size, "justify": justify, "colorDialogue": colorDialogue],
                                  forKey: "look")
    }
}

extension UIColor {
    convenience init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// CSS's color-mix(in srgb, self amount, other).
    func mixed(_ amount: CGFloat, with other: UIColor) -> UIColor {
        UIColor { traits in
            var a = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0)), b = a
            self.resolvedColor(with: traits).getRed(&a.r, green: &a.g, blue: &a.b, alpha: &a.a)
            other.resolvedColor(with: traits).getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.a)
            return UIColor(red: a.r * amount + b.r * (1 - amount), green: a.g * amount + b.g * (1 - amount),
                           blue: a.b * amount + b.b * (1 - amount), alpha: a.a * amount + b.a * (1 - amount))
        }
    }
}
