import SwiftUI

extension View {
    /// Liquid Glass where the system has it (macOS 26), a frosted material before that. For what floats
    /// over the content.
    @ViewBuilder func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// A bead of the same glass under the pointer or when selected, on a row or a small control.
    @ViewBuilder func glassBead<S: Shape>(_ on: Bool, in shape: S) -> some View {
        if on {
            if #available(macOS 26.0, *) {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                background(.quaternary, in: shape)
            }
        } else {
            self
        }
    }
}

/// A press shows at once and lets go quickly; under the pointer it's a bead of glass.
struct GlassButton: ButtonStyle {
    var on = false
    var circle = true
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, on: on, circle: circle) }

    private struct Inner: View {
        let configuration: Configuration
        let on: Bool
        let circle: Bool
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Group {
                if circle {
                    configuration.label.contentShape(Circle()).glassBead(on || hovering, in: Circle())
                } else {
                    configuration.label.contentShape(RoundedRectangle(cornerRadius: 10))
                        .glassBead(on || hovering, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.6 : 1)
            .animation(configuration.isPressed ? nil : .spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
        }
    }
}

/// The main action on a screen: solid, in the text's colour, as on the iPhone.
struct ProminentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }

    private struct Inner: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(scheme == .dark ? Color.white : Color.black, in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .opacity(!enabled ? 0.45 : configuration.isPressed && reduceMotion ? 0.6 : hovering ? 0.88 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(configuration.isPressed ? nil : .spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// CSS's color-mix(in srgb, self amount, other).
    func mixed(_ amount: CGFloat, with other: NSColor) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self, b = other.usingColorSpace(.sRGB) ?? other
        return NSColor(srgbRed: a.redComponent * amount + b.redComponent * (1 - amount), green: a.greenComponent * amount + b.greenComponent * (1 - amount),
                       blue: a.blueComponent * amount + b.blueComponent * (1 - amount), alpha: a.alphaComponent * amount + b.alphaComponent * (1 - amount))
    }
}
