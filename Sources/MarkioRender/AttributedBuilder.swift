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
    /// - Parameter image: resolves a picture for an inline image run, so the
    ///   line can reserve exactly the room it needs. Passing nil draws every
    ///   inline picture as an empty frame — the text is the same either way,
    ///   which is what keeps Find in step with what is drawn.
    static func build(
        content: [UInt8],
        inline: InlineContent,
        theme: Theme,
        baseFont: CTFont,
        baseColor: CGColor,
        skipBytes: Int = 0,
        image: ((InlineLink, CGFloat) -> CGImage?)? = nil
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
                // Alt text describes a picture nobody can see; once the picture
                // itself is on the line it is noise, and the plain-text
                // projection drops it in the same place.
                guard !InlineImage.isHiddenAltText(run: run, inline: inline) else { continue }
                var range = run.range
                if Int(range.start) < skipBytes { range.start = Int32(skipBytes) }
                let text = content.text(in: range)
                guard !text.isEmpty else { continue }
                // A formula this can typeset becomes glyphs of its own; one it
                // cannot keeps its source, and the plain-text projection makes
                // the same choice from the same source.
                if run.style.contains(.math),
                    let formula = MathFormula.box(source: text, base: baseFont, color: baseColor)
                {
                    appendFormula(formula, to: attributed, base: baseFont)
                    break
                }
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
                let link =
                    run.link >= 0 && Int(run.link) < inline.links.count
                    ? inline.links[Int(run.link)] : nil
                if let link, InlineImage.isDrawable(destination: link.destination) {
                    appendPicture(
                        link: link,
                        run: run,
                        to: attributed,
                        base: baseFont,
                        resolve: image
                    )
                } else {
                    // Nothing can be drawn for a remote address, so the marker
                    // and the alt text after it carry the meaning.
                    append(
                        "🖼 ",
                        run: run,
                        to: attributed,
                        theme: theme,
                        base: baseFont,
                        color: theme.palette.secondaryText
                    )
                }
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
        var font = mask.isEmpty ? base : styledFont(base: base, mask: mask, theme: theme)
        // A raised or lowered run is smaller text on a shifted baseline.
        var shift: CGFloat = 0
        if run.style.contains(.raised) || run.style.contains(.lowered) {
            let small = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * 0.72, nil, nil)
            shift = baselineShift(style: run.style, base: base, small: small)
            font = small
        }
        var foreground = color
        if run.style.contains(.link), !isImageAlt { foreground = theme.palette.link }
        if run.style.contains(.math) { foreground = theme.palette.secondaryText }

        var attributes: [NSAttributedString.Key: Any] = [
            fontKey: font,
            colorKey: foreground,
        ]
        if shift != 0 {
            attributes[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = shift
        }
        if run.style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor(cgColor: foreground) ?? NSColor.labelColor
        }
        attributed.append(NSAttributedString(string: text, attributes: attributes))
    }

    /// Reserve room on the line for an inline picture.
    ///
    /// The character is the object replacement; a run delegate gives it the
    /// picture's width and height, and the link index rides along so the laid-
    /// out line can be matched back to the image when it is drawn.
    private static func appendPicture(
        link: InlineLink,
        run: InlineRun,
        to attributed: NSMutableAttributedString,
        base: CTFont,
        resolve: ((InlineLink, CGFloat) -> CGImage?)?
    ) {
        let lineHeight = CTFontGetAscent(base) + CTFontGetDescent(base)
        let picture = resolve?(link, lineHeight * 2.4)
        let size = InlineImage.size(image: picture, lineHeight: lineHeight)
        var attributes: [NSAttributedString.Key: Any] = [
            fontKey: base,
            InlineImage.key: run.link,
        ]
        if let delegate = InlineImage.delegate(size: size) {
            attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
        }
        attributed.append(
            NSAttributedString(string: InlineImage.placeholder, attributes: attributes)
        )
    }

    /// Reserve room on the line for a typeset formula.
    ///
    /// Same shape as a picture: one placeholder character, a run delegate
    /// holding the formula's own metrics, and the laid-out formula riding along
    /// so the block can draw it where the line breaker ended up putting it.
    private static func appendFormula(
        _ formula: MathBox,
        to attributed: NSMutableAttributedString,
        base: CTFont
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            fontKey: base,
            MathFormula.key: formula,
        ]
        if let delegate = MathFormula.delegate(box: formula) {
            attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
        }
        attributed.append(
            NSAttributedString(string: InlineImage.placeholder, attributes: attributes)
        )
    }

    /// How far off the baseline a `<sup>`, `<sub>` or footnote marker sits, in
    /// points.
    ///
    /// The distance is what the base font's own ascent and descent leave over
    /// once the smaller glyphs are placed. Shift a run past those and CoreText
    /// reports a taller line, so the one line of a paragraph that carries a
    /// marker sits further from its neighbour than every other line — a
    /// paragraph with three footnotes in it looks visibly loose. Fitting inside
    /// the metrics keeps the leading even and still puts the marker clearly
    /// above the x-height.
    ///
    /// A raised run takes a negative offset because the text matrix is flipped
    /// — the same flip that lets block offsets be read straight out of the
    /// height index. Get the sign the intuitive way round and superscripts come
    /// out as subscripts, which is exactly how it looked the first time.
    private static func baselineShift(style: InlineStyle, base: CTFont, small: CTFont)
        -> CGFloat
    {
        if style.contains(.raised) {
            return -max(0, CTFontGetAscent(base) - CTFontGetAscent(small)) * 0.9
        }
        if style.contains(.lowered) {
            return max(0, CTFontGetDescent(base) - CTFontGetDescent(small)) * 0.9
        }
        return 0
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
