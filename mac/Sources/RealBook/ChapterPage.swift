import AppKit
import SwiftUI

/// The chapter as the reading page shows it: its paragraphs, a label for who says each quote, dialogue
/// in its speaker's colour, and the line being read highlighted. Click a line to play from it; right
/// click for more.
struct ChapterPage: NSViewRepresentable {
    var reader: Reader
    var look: Look
    var bottomInset: CGFloat
    var dark: Bool
    var onWho: (Int, NSView, NSPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let text = PageTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.coordinator = context.coordinator
        scroll.documentView = text
        context.coordinator.scroll = scroll
        context.coordinator.text = text
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolledByPerson),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let text = c.text else { return }
        let built = [reader.id, String(reader.chapter), String(reader.revision), look.theme, look.font, String(look.size), String(look.justify),
                     String(look.colorDialogue), String(dark), String(reader.chapter + 1 < reader.chapterTitles.count), String(reader.segments.count)].joined(separator: "|")
        if c.built != built {
            let sameChapter = c.built.hasPrefix("\(reader.id)|\(reader.chapter)|")
            text.textStorage?.setAttributedString(c.page())
            c.built = built
            c.highlighted = nil
            c.jump = !sameChapter || reader.following
        }
        text.bottomInset = bottomInset
        text.layoutPage()
        c.highlight()
        if c.jump {
            c.jump = false
            DispatchQueue.main.async { c.scrollToCurrent(animated: false, force: true) }
        } else if reader.following {
            c.scrollToCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, force: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ChapterPage
        weak var scroll: NSScrollView?
        weak var text: PageTextView?
        var built = ""
        var ranges: [Int: NSRange] = [:]
        var highlighted: Int?
        var jump = false
        var hovered: Int?

        init(_ parent: ChapterPage) { self.parent = parent }

        @objc func scrolledByPerson() { parent.reader.scrolledAway() }

        func page() -> NSAttributedString {
            let p = parent, theme = p.look.current
            let ink = p.dark && p.look.current.dark == nil ? theme.ink : theme.ink, muted = theme.muted
            let body = p.look.font()
            let size = body.pointSize
            let out = NSMutableAttributedString()
            ranges = [:]
            let centered = { (before: CGFloat, after: CGFloat) -> NSParagraphStyle in
                let s = NSMutableParagraphStyle()
                s.alignment = .center
                s.paragraphSpacingBefore = before
                s.paragraphSpacing = after
                return s
            }
            if !p.reader.section.isEmpty {
                let font = NSFont.systemFont(ofSize: round(size * 0.66), weight: .medium)
                out.append(NSAttributedString(string: p.reader.section.uppercased() + "\n", attributes: [
                    .font: font, .kern: font.pointSize * 0.14, .foregroundColor: muted.withAlphaComponent(0.8), .paragraphStyle: centered(size * 1.4, size * 0.5)]))
            }
            let heading = NSFont.systemFont(ofSize: round(size * 0.8), weight: .semibold)
            out.append(NSAttributedString(string: p.reader.title.uppercased() + "\n", attributes: [
                .font: heading, .kern: heading.pointSize * 0.14, .foregroundColor: muted, .paragraphStyle: centered(p.reader.section.isEmpty ? size * 1.6 : 0, size * 1.6)]))

            let style = NSMutableParagraphStyle()
            style.alignment = p.look.justify ? .justified : .natural
            style.lineSpacing = size * 0.38
            style.paragraphSpacing = size * 0.8
            style.hyphenationFactor = p.look.justify ? 0.9 : 0.4
            var para: Int?
            var lastWho: String?
            let lines = p.reader.segments
            for (i, line) in lines.enumerated() {
                if line.para != para {
                    if para != nil { out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: style])) }
                    para = line.para
                    lastWho = nil
                }
                let dialogue = line.kind == "dialogue"
                let together = { (a: MacChapter.Segment?, b: MacChapter.Segment) -> Bool in
                    guard let a, a.kind == "dialogue", b.kind == "dialogue", a.para == b.para || a.q != nil else { return false }
                    return a.q != nil ? a.q == b.q : a.speaker == b.speaker
                }
                let first = dialogue && !together(i > 0 ? lines[i - 1] : nil, line)
                let last = dialogue && !(i + 1 < lines.count ? together(line, lines[i + 1]) : false)
                if first && line.speaker != lastWho {
                    out.append(chip(line, body: body, theme: theme, style: style))
                    lastWho = line.speaker
                }
                var words = line.text
                if first { words = "“" + words }
                if last { words += "”" }
                var attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: ink, .paragraphStyle: style, .rbSegment: line.id]
                if dialogue, let who = line.speaker, p.look.colorDialogue, let hex = p.reader.colors[who] {
                    attrs[.foregroundColor] = NSColor(hex: hex).mixed(0.72, with: ink)
                } else if dialogue && line.speaker == nil {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    attrs[.underlineColor] = muted
                }
                let start = out.length
                out.append(NSAttributedString(string: words, attributes: attrs))
                ranges[line.id] = NSRange(location: start, length: out.length - start)
                out.append(NSAttributedString(string: " ", attributes: [.font: body, .paragraphStyle: style]))
            }
            if p.reader.chapter + 1 < p.reader.chapterTitles.count {
                let font = NSFont.systemFont(ofSize: round(size * 0.8), weight: .semibold)
                out.append(NSAttributedString(string: "\nNext Chapter ›", attributes: [
                    .font: font, .foregroundColor: ink.withAlphaComponent(0.75), .rbNext: true, .paragraphStyle: centered(size * 2.2, 0)]))
            }
            return out
        }

        /// The label before a quote saying who says it: a tinted capsule.
        private func chip(_ line: MacChapter.Segment, body: NSFont, theme: Look.Theme, style: NSParagraphStyle) -> NSAttributedString {
            let tint = line.speaker.flatMap { parent.reader.colors[$0] }.map { NSColor(hex: $0) } ?? theme.muted
            let font = NSFont.systemFont(ofSize: max(10, round(body.pointSize * 0.58)), weight: .semibold)
            let label = NSAttributedString(string: line.speaker.flatMap(parent.reader.name) ?? "?", attributes: [
                .font: font, .foregroundColor: tint.mixed(0.8, with: theme.ink), .kern: 0.2])
            let size = label.size()
            let h = ceil(size.height + 3), w = ceil(size.width + 12), gap = round(body.pointSize * 0.3)
            let image = NSImage(size: NSSize(width: w + gap, height: h), flipped: false) { _ in
                tint.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
                label.draw(at: NSPoint(x: 6, y: (h - size.height) / 2))
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: round((body.capHeight - h) / 2), width: w + gap, height: h)
            let s = NSMutableAttributedString(attachment: attachment)
            s.addAttributes([.rbWho: line.id, .paragraphStyle: style, .font: body], range: NSRange(location: 0, length: s.length))
            return s
        }

        func highlight() {
            guard let storage = text?.textStorage, highlighted != parent.reader.segment else { return }
            if let old = highlighted, let r = ranges[old], NSMaxRange(r) <= storage.length { storage.removeAttribute(.backgroundColor, range: r) }
            highlighted = parent.reader.segment
            if let now = highlighted, let r = ranges[now], NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: parent.look.current.highlight, range: r)
            }
        }

        func rect(of range: NSRange) -> NSRect? {
            guard let text, let lm = text.layoutManager, let tc = text.textContainer, NSMaxRange(range) <= (text.textStorage?.length ?? 0) else { return nil }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let origin = text.textContainerOrigin
            return lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: origin.x, dy: origin.y)
        }

        /// Keeps the line being read in view: scrolls when it nears the top or the player at the bottom.
        func scrollToCurrent(animated: Bool, force: Bool) {
            guard let scroll, let text, let r = ranges[parent.reader.segment], let line = rect(of: r) else { return }
            let clip = scroll.contentView
            let top = clip.bounds.origin.y, visible = clip.bounds.height - parent.bottomInset
            guard force || line.minY < top + 30 || line.maxY > top + visible - 30 else { return }
            let most = max(0, text.frame.height - clip.bounds.height)
            // Near the start of a chapter it stays at the top, so the chapter's title stays in view.
            let fitsAtTop = line.maxY < visible - 30
            let y = fitsAtTop ? 0 : min(max(0, line.minY - max(40, (visible - line.height) * 0.3)), most)
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
                }
            } else {
                clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            }
            scroll.reflectScrolledClipView(clip)
        }

        func attributes(at point: NSPoint) -> [NSAttributedString.Key: Any]? {
            guard let text, let lm = text.layoutManager, let tc = text.textContainer, (text.textStorage?.length ?? 0) > 0 else { return nil }
            let origin = text.textContainerOrigin
            let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: nil)
            guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).insetBy(dx: -4, dy: -3).contains(p) else { return nil }
            let char = lm.characterIndexForGlyph(at: glyph)
            return char < text.textStorage!.length ? text.textStorage!.attributes(at: char, effectiveRange: nil) : nil
        }

        func clicked(at point: NSPoint) {
            guard let attrs = attributes(at: point), let text else { return }
            if let s = attrs[.rbWho] as? Int {
                parent.onWho(s, text, point)
            } else if let s = attrs[.rbSegment] as? Int {
                parent.reader.go(to: s, play: true)
            } else if attrs[.rbNext] != nil {
                parent.reader.goTo(chapter: parent.reader.chapter + 1)
            }
        }

        func hover(at point: NSPoint?) {
            let s = point.flatMap { attributes(at: $0) }.flatMap { ($0[.rbSegment] ?? $0[.rbWho]) as? Int }
            guard s != hovered, let lm = text?.layoutManager else { return }
            if let old = hovered, let r = ranges[old] { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
            hovered = s
            if let s, let r = ranges[s], s != parent.reader.segment {
                lm.addTemporaryAttribute(.backgroundColor, value: parent.look.current.ink.withAlphaComponent(0.06), forCharacterRange: r)
            }
            NSCursor.arrow.set()
        }

        func menu(at point: NSPoint) -> NSMenu? {
            guard let attrs = attributes(at: point), let s = (attrs[.rbSegment] ?? attrs[.rbWho]) as? Int else { return nil }
            let menu = NSMenu()
            menu.addItem(ClosureItem("Play From Here") { [weak self] in self?.parent.reader.go(to: s, play: true) })
            menu.addItem(ClosureItem("Read This Line Again") { [weak self] in
                guard let reader = self?.parent.reader else { return }
                Task { await reader.readAgain(s) }
            })
            if parent.reader.segments.first(where: { $0.id == s })?.kind == "dialogue" {
                menu.addItem(.separator())
                menu.addItem(ClosureItem("Who Says This…") { [weak self] in
                    guard let self, let text = self.text else { return }
                    self.parent.onWho(s, text, point)
                })
            }
            let line = parent.reader.segments.first { $0.id == s }?.text ?? ""
            menu.addItem(.separator())
            menu.addItem(ClosureItem("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            })
            return menu
        }
    }
}

final class PageTextView: NSTextView {
    weak var coordinator: ChapterPage.Coordinator?
    var bottomInset: CGFloat = 0
    private let column: CGFloat = 700

    /// A column in the middle, however wide the window, with room for the player under the last line.
    func layoutPage() {
        let side = max(40, (bounds.width - column) / 2)
        textContainerInset = NSSize(width: side, height: 24)
        guard let tc = textContainer else { return }
        tc.containerSize = NSSize(width: bounds.width - 2 * side, height: .greatestFiniteMagnitude)
    }

    /// Always at the top of its scroll view. Resizing would otherwise move it up when the scroll view
    /// gets shorter (as when the toolbar appears), hiding the chapter's title and first lines for good.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(.zero)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPage()
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.clicked(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { coordinator?.hover(at: nil) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func menu(for event: NSEvent) -> NSMenu? { coordinator?.menu(at: convert(event.locationInWindow, from: nil)) }
}

final class ClosureItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

extension NSAttributedString.Key {
    static let rbSegment = NSAttributedString.Key("realbook.segment")
    static let rbWho = NSAttributedString.Key("realbook.who")
    static let rbNext = NSAttributedString.Key("realbook.next")
}
