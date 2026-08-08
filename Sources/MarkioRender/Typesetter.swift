import AppKit
import CoreText

/// One typeset line, positioned in the block's own coordinate space.
///
/// Coordinates are flipped (y grows downward) because the document view is
/// flipped; a scroll offset then adds directly to a block's y without any
/// conversion, which is what keeps the hot path free of arithmetic.
struct TextLine {
    var line: CTLine
    /// Baseline origin, left edge.
    var origin: CGPoint
    var range: CFRange
    var ascent: CGFloat
    var descent: CGFloat
    var width: CGFloat

    /// The line's ink box, used for hit testing and selection rectangles.
    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y - ascent, width: width, height: ascent + descent)
    }
}

enum LineAlignment {
    case left
    case center
    case right
}

/// Breaks attributed text into lines at a given width.
///
/// Line breaking is driven directly rather than through `CTFrame` so that each
/// block can be laid out independently at its own indent, and so that a block's
/// lines can be produced and thrown away without touching the ones around it —
/// the property the whole virtualized layout rests on.
enum Typesetter {
    struct Result {
        var lines: [TextLine]
        var height: CGFloat
        var maxWidth: CGFloat
    }

    static func layout(
        _ attributed: NSAttributedString,
        width: CGFloat,
        x: CGFloat,
        y startY: CGFloat,
        lineHeightMultiple: CGFloat,
        alignment: LineAlignment = .left
    ) -> Result {
        let length = attributed.length
        guard length > 0, width > 1 else {
            return Result(lines: [], height: 0, maxWidth: 0)
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let text = attributed.string as NSString
        var lines: [TextLine] = []
        var y = startY
        var maxWidth: CGFloat = 0
        var paragraphStart = 0

        while paragraphStart <= length {
            let remaining = NSRange(
                location: paragraphStart,
                length: max(0, length - paragraphStart)
            )
            let newline =
                remaining.length > 0
                ? text.rangeOfCharacter(from: .newlines, range: remaining)
                : NSRange(location: NSNotFound, length: 0)
            let paragraphEnd = newline.location == NSNotFound ? length : newline.location

            if paragraphEnd == paragraphStart {
                // An explicit break with no text on the line still takes a line.
                y += emptyLineHeight(attributed, at: paragraphStart, multiple: lineHeightMultiple)
            } else {
                var lineStart = paragraphStart
                while lineStart < paragraphEnd {
                    var count = CTTypesetterSuggestLineBreak(
                        typesetter,
                        lineStart,
                        Double(width)
                    )
                    // A width narrower than one glyph would otherwise loop forever.
                    if count <= 0 { count = 1 }
                    if lineStart + count > paragraphEnd { count = paragraphEnd - lineStart }
                    let range = CFRange(location: lineStart, length: count)
                    let line = CTTypesetterCreateLine(typesetter, range)
                    let (ascent, descent, leading) = metrics(of: line)
                    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    let advance = (ascent + descent + leading) * lineHeightMultiple
                    let baseline = y + ascent + (advance - ascent - descent) / 2
                    let offsetX: CGFloat
                    switch alignment {
                    case .left: offsetX = 0
                    case .center: offsetX = max(0, (width - lineWidth) / 2)
                    case .right: offsetX = max(0, width - lineWidth)
                    }
                    lines.append(
                        TextLine(
                            line: line,
                            origin: CGPoint(x: x + offsetX, y: baseline),
                            range: range,
                            ascent: ascent,
                            descent: descent,
                            width: lineWidth
                        )
                    )
                    maxWidth = max(maxWidth, lineWidth)
                    y += advance
                    lineStart += count
                }
            }
            if paragraphEnd >= length { break }
            paragraphStart = paragraphEnd + newline.length
        }
        return Result(lines: lines, height: y - startY, maxWidth: maxWidth)
    }

    /// A line's height, with baseline shifts taken back out.
    ///
    /// `CTLineGetTypographicBounds` folds a run's baseline offset straight into
    /// the line's descent, so a single superscript makes exactly one line of a
    /// paragraph taller and the leading around it visibly uneven. Each run
    /// reports its own unshifted height, and a shift is sized to stay inside
    /// what the base font's ascent and descent already allow — so the maximum
    /// over the runs is the height the line really needs. An inline picture
    /// carries no offset at all: its run delegate reports the room it reserved,
    /// and the line still grows to hold it.
    private static func metrics(of line: CTLine) -> (
        ascent: CGFloat, descent: CGFloat, leading: CGFloat
    ) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        var sawRun = false
        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
            var runAscent: CGFloat = 0
            var runDescent: CGFloat = 0
            var runLeading: CGFloat = 0
            _ = CTRunGetTypographicBounds(run, CFRange(), &runAscent, &runDescent, &runLeading)
            ascent = max(ascent, runAscent)
            descent = max(descent, runDescent)
            leading = max(leading, runLeading)
            sawRun = true
        }
        guard sawRun else {
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return (ascent, descent, leading)
        }
        return (ascent, descent, leading)
    }

    /// One line placed at an exact baseline.
    ///
    /// Used for list markers, which must sit on the same baseline as the first
    /// line of the item's text. Going through `layout` would place them by line
    /// box instead, which drops them by half the leading — visible as bullets
    /// that sag below their text.
    static func singleLine(
        _ attributed: NSAttributedString,
        x: CGFloat,
        width: CGFloat,
        baseline: CGFloat,
        alignment: LineAlignment
    ) -> TextLine? {
        guard attributed.length > 0 else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let offsetX: CGFloat
        switch alignment {
        case .left: offsetX = 0
        case .center: offsetX = max(0, (width - lineWidth) / 2)
        case .right: offsetX = max(0, width - lineWidth)
        }
        return TextLine(
            line: line,
            origin: CGPoint(x: x + offsetX, y: baseline),
            range: CFRange(location: 0, length: attributed.length),
            ascent: ascent,
            descent: descent,
            width: lineWidth
        )
    }

    /// Height of a line that has no glyphs of its own, taken from the font in
    /// effect there so a blank line inside a code block matches the code.
    private static func emptyLineHeight(
        _ attributed: NSAttributedString,
        at index: Int,
        multiple: CGFloat
    ) -> CGFloat {
        let probe = min(max(0, index), max(0, attributed.length - 1))
        guard attributed.length > 0,
            let font = attributed.attribute(
                AttributedBuilder.fontKey,
                at: probe,
                effectiveRange: nil
            ) as? NSFont
        else { return 0 }
        let ctFont = font as CTFont
        return (CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
            * multiple
    }
}
