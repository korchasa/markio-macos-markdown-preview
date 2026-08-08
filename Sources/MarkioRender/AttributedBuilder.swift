import AppKit
import CoreText
import MarkdownKit

/// Turns a block's inline runs into an attributed string plus the span list the
/// layout needs in order to draw backgrounds and underlines.
///
/// CoreText attributes cover the font and the colour; a code span's rounded
/// background and a link's underline are geometry, not text attributes, so they
/// are recorded as spans and resolved into rectangles once the line breaks are
/// known.
struct StyledText {
    var attributed: NSMutableAttributedString
    var spans: [Span]

    struct Span {
        /// Range in the attributed string (UTF-16 offsets).
        var range: NSRange
        var style: InlineStyle
        var link: Int32
    }

    var isEmpty: Bool { attributed.length == 0 }
}

enum AttributedBuilder {
    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    /// Build the attributed text of a block from its parsed inline runs.
    ///
    /// `baseFont` and `baseColor` are what unstyled text uses; a heading passes
    /// its own so the whole block scales without a second attribute pass.
    static func build(
        content: [UInt8],
        inline: InlineContent,
        theme: Theme,
        baseFont: CTFont,
        baseColor: CGColor,
        skipBytes: Int = 0
    ) -> StyledText {
        let attributed = NSMutableAttributedString()
        var spans: [StyledText.Span] = []
        spans.reserveCapacity(inline.runs.count)

        for run in inline.runs {
            let start = attributed.length
            // Alt text belongs to a picture, not to a destination: styling it
            // as a link would invite a click that goes nowhere.
            let isImageAlt =
                run.link >= 0 && Int(run.link) < inline.links.count
                && inline.links[Int(run.link)].isImage
            switch run.kind {
            case .text:
                guard Int(run.range.end) > skipBytes else { continue }
                var range = run.range
                if Int(range.start) < skipBytes { range.start = Int32(skipBytes) }
                let text = content.text(in: range)
                guard !text.isEmpty else { continue }
                append(
                    text,
                    run: run,
                    to: attributed,
                    theme: theme,
                    base: baseFont,
                    color: baseColor,
                    isImageAlt: isImageAlt
                )
            case .entity:
                guard let scalar = Unicode.Scalar(run.scalar) else { continue }
                append(
                    String(Character(scalar)),
                    run: run,
                    to: attributed,
                    theme: theme,
                    base: baseFont,
                    color: baseColor
                )
            case .softBreak:
                // A single newline in the source is a space on screen; that is
                // what makes a hand-wrapped paragraph reflow at any width.
                append(
                    " ", run: run, to: attributed, theme: theme, base: baseFont, color: baseColor)
            case .hardBreak:
                append(
                    "\n",
                    run: run,
                    to: attributed,
                    theme: theme,
                    base: baseFont,
                    color: baseColor
                )
            case .image:
                // No image decoding yet; the alt text that follows carries the
                // meaning, and a marker keeps the reader aware something is there.
                append(
                    "🖼 ",
                    run: run,
                    to: attributed,
                    theme: theme,
                    base: baseFont,
                    color: theme.palette.secondaryText
                )
            }
            let length = attributed.length - start
            if length > 0, !run.style.isEmpty || run.link >= 0 {
                spans.append(
                    StyledText.Span(
                        range: NSRange(location: start, length: length),
                        style: run.style,
                        link: isImageAlt ? -1 : run.link
                    )
                )
            }
        }
        return StyledText(attributed: attributed, spans: spans)
    }

    private static func append(
        _ text: String,
        run: InlineRun,
        to attributed: NSMutableAttributedString,
        theme: Theme,
        base: CTFont,
        color: CGColor,
        isImageAlt: Bool = false
    ) {
        var mask: InlineStyleMask = []
        if run.style.contains(.strong) { mask.insert(.bold) }
        if run.style.contains(.emphasis) { mask.insert(.italic) }
        if run.style.contains(.code) || run.style.contains(.math)
            || run.style.contains(.keyboard)
        {
            mask.insert(.monospaced)
        }
        let font = mask.isEmpty ? base : styledFont(base: base, mask: mask, theme: theme)
        var foreground = color
        if run.style.contains(.link), !isImageAlt { foreground = theme.palette.link }
        if run.style.contains(.math) { foreground = theme.palette.secondaryText }

        var attributes: [NSAttributedString.Key: Any] = [
            fontKey: font,
            colorKey: foreground,
        ]
        if run.style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor(cgColor: foreground) ?? NSColor.labelColor
        }
        attributed.append(NSAttributedString(string: text, attributes: attributes))
    }

    /// Derive a styled font from the block's base font, so a bold run inside a
    /// heading stays heading-sized.
    private static func styledFont(base: CTFont, mask: InlineStyleMask, theme: Theme) -> CTFont {
        if mask.contains(.monospaced) {
            let size = CTFontGetSize(base) * 0.92
            return NSFont.monospacedSystemFont(
                ofSize: size,
                weight: mask.contains(.bold) ? .bold : .regular
            ) as CTFont
        }
        var traits: CTFontSymbolicTraits = []
        if mask.contains(.bold) { traits.insert(.traitBold) }
        if mask.contains(.italic) { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
    }
}
