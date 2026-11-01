import SwiftUI
import UIKit

/// A chapter laid out as on the Mac's reading page: its paragraphs, a label for who says each quote,
/// dialogue in its speaker's colour, and the line being read highlighted. Tap a line to play from
/// it; hold it for more.
struct ChapterPage: UIViewRepresentable {
    var key: String        // the book and chapter
    var revision: Int      // bumps when the text or its speakers change
    var lines: [PageLine]
    var title: String
    var section: String?
    var current: Int?
    var follow: Bool
    var look: Look
    var scheme: ColorScheme
    var hasNext: Bool
    var bottomInset: CGFloat
    var name: (String) -> String?
    var color: (String) -> String?
    var onTap: (Int) -> Void
    var onWho: (Int) -> Void
    var onNext: () -> Void
    var onScrolledAway: () -> Void
    var menu: (Int) -> UIMenu?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PageTextView {
        let tv = PageTextView(usingTextLayoutManager: false)  // TextKit 1: exact places for lines, to scroll to and tap
        tv.isEditable = false
        tv.isSelectable = false
        tv.alwaysBounceVertical = true
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        tv.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        tv.onLayout = { [weak coordinator = context.coordinator] in coordinator?.laidOut() }
        context.coordinator.view = tv
        return tv
    }

    func updateUIView(_ tv: PageTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        tv.backgroundColor = look.current.background
        let side: CGFloat = 24
        tv.textContainerInset = UIEdgeInsets(top: 4, left: side, bottom: bottomInset + 30, right: side)
        let built = [key, String(revision), look.theme, look.font, String(look.size), String(look.justify), String(look.colorDialogue),
                     scheme == .dark ? "dark" : "light", String(hasNext)].joined(separator: "|")
        if c.built != built {
            let sameChapter = c.built.hasPrefix(key + "|")
            let offset = tv.contentOffset
            tv.attributedText = c.page()
            c.built = built
            c.highlighted = nil
            if sameChapter && !follow {
                tv.layoutIfNeeded()
                tv.contentOffset = offset
            } else {
                c.jump = true
                tv.setNeedsLayout()
            }
        }
        c.highlight()
        if follow && !c.jump { c.scrollToCurrent(animated: !UIAccessibility.isReduceMotionEnabled, force: false) }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIContextMenuInteractionDelegate {
        var parent: ChapterPage
        weak var view: PageTextView?
        var built = ""
        var ranges: [Int: NSRange] = [:]
        var highlighted: Int?
        var jump = false

        init(_ parent: ChapterPage) { self.parent = parent }

        // MARK: laying out the page

        func page() -> NSAttributedString {
            let p = parent, theme = p.look.current
            let traits = UITraitCollection(userInterfaceStyle: p.scheme == .dark ? .dark : .light)
            let ink = theme.ink.resolvedColor(with: traits), muted = theme.muted.resolvedColor(with: traits)
            let body = p.look.uiFont()
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
            if let section = p.section {
                let font = UIFont.systemFont(ofSize: round(size * 0.66), weight: .medium)
                out.append(NSAttributedString(string: section.uppercased() + "\n", attributes: [
                    .font: font, .kern: font.pointSize * 0.14, .foregroundColor: muted.withAlphaComponent(0.8),
                    .paragraphStyle: centered(size * 1.4, size * 0.5)]))
            }
            let heading = UIFont.systemFont(ofSize: round(size * 0.8), weight: .semibold)
            out.append(NSAttributedString(string: p.title.uppercased() + "\n", attributes: [
                .font: heading, .kern: heading.pointSize * 0.14, .foregroundColor: muted,
                .paragraphStyle: centered(p.section == nil ? size * 1.6 : 0, size * 1.6)]))

            let style = NSMutableParagraphStyle()
            style.alignment = p.look.justify ? .justified : .natural
            style.lineSpacing = size * 0.38
            style.paragraphSpacing = size * 0.8
            style.hyphenationFactor = p.look.justify ? 0.9 : 0.4
            var para: Int?
            var lastWho: String?
            for (i, line) in p.lines.enumerated() {
                if line.para != para {
                    if para != nil { out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: style])) }
                    para = line.para
                    lastWho = nil
                }
                let prev = i > 0 ? p.lines[i - 1] : nil, next = i + 1 < p.lines.count ? p.lines[i + 1] : nil
                let together = { (a: PageLine?, b: PageLine) -> Bool in
                    guard let a, a.dialogue, b.dialogue, a.para == b.para || a.q != nil else { return false }
                    return a.q != nil ? a.q == b.q : a.speaker == b.speaker
                }
                let firstOfQuote = line.dialogue && !together(prev, line)
                let lastOfQuote = line.dialogue && !(next.map { together(line, $0) } ?? false)
                if firstOfQuote && line.speaker != lastWho {
                    out.append(chip(line, body: body, theme: theme, traits: traits, style: style))
                    lastWho = line.speaker
                }
                var text = line.text
                if firstOfQuote { text = "“" + text }
                if lastOfQuote { text += "”" }
                var attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: ink, .paragraphStyle: style, .rbSegment: line.segment]
                if line.dialogue, let who = line.speaker, p.look.colorDialogue, let hex = p.color(who) {
                    attrs[.foregroundColor] = UIColor(hex: hex).mixed(0.72, with: ink).resolvedColor(with: traits)
                } else if line.dialogue && line.speaker == nil {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    attrs[.underlineColor] = muted
                }
                let start = out.length
                out.append(NSAttributedString(string: text, attributes: attrs))
                ranges[line.segment] = NSRange(location: start, length: out.length - start)
                out.append(NSAttributedString(string: " ", attributes: [.font: body, .paragraphStyle: style]))
            }
            if p.hasNext {
                let font = UIFont.systemFont(ofSize: round(size * 0.8), weight: .semibold)
                out.append(NSAttributedString(string: "\nNext Chapter ›", attributes: [
                    .font: font, .foregroundColor: ink.withAlphaComponent(0.75), .rbNext: true,
                    .paragraphStyle: centered(size * 2.2, 0)]))
            }
            return out
        }

        /// The label before a quote saying who says it, as on the Mac: a tinted capsule.
        private func chip(_ line: PageLine, body: UIFont, theme: Look.Theme, traits: UITraitCollection, style: NSParagraphStyle) -> NSAttributedString {
            let tint = (line.speaker.flatMap(parent.color).map { UIColor(hex: $0) } ?? theme.muted).resolvedColor(with: traits)
            let ink = theme.ink.resolvedColor(with: traits)
            let font = UIFont.systemFont(ofSize: max(10, round(body.pointSize * 0.58)), weight: .semibold)
            let label = NSAttributedString(string: line.speaker.flatMap(parent.name) ?? "?", attributes: [
                .font: font, .foregroundColor: tint.mixed(0.8, with: ink).resolvedColor(with: traits), .kern: 0.2])
            let textSize = label.size()
            let h = ceil(font.lineHeight + 3), w = ceil(textSize.width + 12), gap = round(body.pointSize * 0.3)
            let image = UIGraphicsImageRenderer(size: CGSize(width: w + gap, height: h)).image { _ in
                tint.withAlphaComponent(0.16).setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: h / 2).fill()
                label.draw(at: CGPoint(x: 6, y: (h - textSize.height) / 2))
            }
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = CGRect(x: 0, y: round((body.capHeight - h) / 2), width: w + gap, height: h)
            let s = NSMutableAttributedString(attachment: attachment)
            s.addAttributes([.rbWho: line.segment, .paragraphStyle: style, .font: body], range: NSRange(location: 0, length: s.length))
            return s
        }

        // MARK: the line being read

        func highlight() {
            guard let tv = view, highlighted != parent.current else { return }
            let storage = tv.textStorage
            if let old = highlighted, let r = ranges[old], NSMaxRange(r) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: r)
            }
            highlighted = parent.current
            if let now = parent.current, let r = ranges[now], NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: parent.look.current.highlight, range: r)
            }
        }

        func laidOut() {
            guard jump, let tv = view, tv.bounds.height > 0 else { return }
            jump = false
            if parent.current != nil {
                scrollToCurrent(animated: false, force: true)
            } else {
                tv.setContentOffset(CGPoint(x: 0, y: -tv.adjustedContentInset.top), animated: false)
            }
        }

        private func rect(of range: NSRange) -> CGRect? {
            guard let tv = view, NSMaxRange(range) <= tv.textStorage.length else { return nil }
            let lm = tv.layoutManager
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return lm.boundingRect(forGlyphRange: glyphs, in: tv.textContainer)
                .offsetBy(dx: tv.textContainerInset.left, dy: tv.textContainerInset.top)
        }

        /// Keeps the line being read in view: scrolls when it nears the top or the player at the bottom.
        func scrollToCurrent(animated: Bool, force: Bool) {
            guard let tv = view, let now = parent.current, let r = ranges[now], let line = rect(of: r) else { return }
            let insets = tv.adjustedContentInset
            let top = tv.contentOffset.y + insets.top
            let visible = tv.bounds.height - insets.top - insets.bottom - parent.bottomInset
            guard force || line.minY < top + 30 || line.maxY > top + visible - 30 else { return }
            let target = line.minY - insets.top - max(40, (visible - line.height) * 0.3)
            let most = max(-insets.top, tv.contentSize.height - tv.bounds.height + insets.bottom)
            tv.setContentOffset(CGPoint(x: 0, y: min(max(-insets.top, target), most)), animated: animated)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.onScrolledAway() }

        // MARK: tapping and holding

        private func hit(_ point: CGPoint) -> [NSAttributedString.Key: Any]? {
            guard let tv = view, tv.textStorage.length > 0 else { return nil }
            let lm = tv.layoutManager
            let p = CGPoint(x: point.x - tv.textContainerInset.left, y: point.y - tv.textContainerInset.top)
            let glyph = lm.glyphIndex(for: p, in: tv.textContainer, fractionOfDistanceThroughGlyph: nil)
            let box = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tv.textContainer)
            guard box.insetBy(dx: -8, dy: -6).contains(p) else { return nil }
            let char = lm.characterIndexForGlyph(at: glyph)
            return char < tv.textStorage.length ? tv.textStorage.attributes(at: char, effectiveRange: nil) : nil
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let tv = view, let attrs = hit(g.location(in: tv)) else { return }
            if let s = attrs[.rbWho] as? Int {
                parent.onWho(s)
            } else if let s = attrs[.rbSegment] as? Int {
                parent.onTap(s)
            } else if attrs[.rbNext] != nil {
                parent.onNext()
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let attrs = hit(location), let s = (attrs[.rbSegment] ?? attrs[.rbWho]) as? Int, let menu = parent.menu(s) else { return nil }
            return UIContextMenuConfiguration(identifier: NSNumber(value: s), previewProvider: nil) { _ in menu }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            guard let tv = view, let s = (identifier as? NSNumber)?.intValue, let r = ranges[s] else { return nil }
            let lm = tv.layoutManager
            let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var rects: [NSValue] = []
            lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: tv.textContainer) { rect, _ in
                rects.append(NSValue(cgRect: rect.offsetBy(dx: tv.textContainerInset.left, dy: tv.textContainerInset.top)))
            }
            guard !rects.isEmpty else { return nil }
            let params = UIPreviewParameters(textLineRects: rects)
            params.backgroundColor = parent.look.current.background
            return UITargetedPreview(view: tv, parameters: params)
        }
    }
}

final class PageTextView: UITextView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

extension NSAttributedString.Key {
    static let rbSegment = NSAttributedString.Key("realbook.segment")
    static let rbWho = NSAttributedString.Key("realbook.who")
    static let rbNext = NSAttributedString.Key("realbook.next")
}
