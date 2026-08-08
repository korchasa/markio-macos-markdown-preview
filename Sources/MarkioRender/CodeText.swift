import AppKit
import MarkdownKit

/// The contents of a fenced block, coloured by whichever source applies.
///
/// Three kinds of colour can reach a code block, and only one of them is
/// syntax. A pasted terminal log carries its colour in escape sequences, and a
/// `diff` block carries it in the first character of each line. Both are how
/// people actually paste output into documents, and neither is a language a
/// highlighter could know.
struct CodeText {
    var attributed: NSAttributedString
    /// The characters the block contributes to Find and Copy. Not always the
    /// source: escape sequences are removed.
    var text: String
    /// Backgrounds to paint behind ranges of the text. `fullWidth` marks the
    /// ones that should span the block rather than hug the glyphs — a changed
    /// line in a diff reads as a band, not as a highlighted phrase.
    var tints: [Tint]

    struct Tint {
        var range: NSRange
        var color: CGColor
        var fullWidth: Bool
    }

    /// Highlighting a very large block would cost more than it is worth; past
    /// this size the block is a log or a data dump, not code.
    private static let highlightLimit = 128 * 1_024

    static func build(
        content: [UInt8],
        language: String,
        dimmed: Bool,
        theme: Theme,
        syntax: SyntaxHighlighter.Palette
    ) -> CodeText {
        let base = dimmed ? theme.palette.secondaryText : theme.palette.codeText
        if language.lowercased() == "diff" {
            return diff(content: content, base: base, theme: theme)
        }
        if AnsiText.containsEscapes(content) {
            return ansi(content: content, base: base, theme: theme)
        }
        return highlighted(
            content: content,
            language: language,
            base: base,
            theme: theme,
            syntax: syntax
        )
    }

    // MARK: - Sources

    private static func highlighted(
        content: [UInt8],
        language: String,
        base: CGColor,
        theme: Theme,
        syntax: SyntaxHighlighter.Palette
    ) -> CodeText {
        let builder = Builder(theme: theme)
        let spans =
            content.count <= highlightLimit
            ? SyntaxHighlighter.spans(code: content, language: language)
            : []
        var cursor = 0
        for span in spans {
            guard span.start >= cursor, span.end <= content.count else { continue }
            builder.append(content[cursor..<span.start], color: base)
            builder.append(
                content[span.start..<span.end],
                color: syntax.color(for: span.token, fallback: base)
            )
            cursor = span.end
        }
        builder.append(content[cursor...], color: base)
        return builder.finish()
    }

    private static func ansi(content: [UInt8], base: CGColor, theme: Theme) -> CodeText {
        let parsed = AnsiText.parse(content, palette: AnsiText.Palette(isDark: theme.isDark))
        let builder = Builder(theme: theme)
        var cursor = 0
        for span in parsed.spans {
            guard span.start >= cursor, span.end <= parsed.text.count else { continue }
            builder.append(parsed.text[cursor..<span.start], color: base)
            let start = builder.length
            builder.append(
                parsed.text[span.start..<span.end],
                color: span.color ?? base,
                bold: span.bold
            )
            if let background = span.background {
                builder.tint(from: start, color: background, fullWidth: false)
            }
            cursor = span.end
        }
        builder.append(parsed.text[cursor...], color: base)
        return builder.finish()
    }

    private static func diff(content: [UInt8], base: CGColor, theme: Theme) -> CodeText {
        let builder = Builder(theme: theme)
        var index = 0
        while index < content.count {
            var end = index
            while end < content.count, content[end] != 0x0A { end += 1 }
            // The newline belongs to the line, so the band covers it and the
            // next line starts clean.
            let lineEnd = min(end + 1, content.count)
            let marker = content[index]
            let start = builder.length
            let colors = tint(for: marker, theme: theme, base: base)
            builder.append(content[index..<lineEnd], color: colors.text)
            if let background = colors.background {
                builder.tint(from: start, color: background, fullWidth: true)
            }
            index = lineEnd
        }
        return builder.finish()
    }

    private static func tint(
        for marker: UInt8,
        theme: Theme,
        base: CGColor
    ) -> (text: CGColor, background: CGColor?) {
        switch marker {
        case 0x2B:  // '+'
            return (theme.palette.diffAddedText, theme.palette.diffAddedBackground)
        case 0x2D:  // '-'
            return (theme.palette.diffRemovedText, theme.palette.diffRemovedBackground)
        case 0x40:  // '@', the hunk header
            return (theme.palette.secondaryText, nil)
        default:
            return (base, nil)
        }
    }

    // MARK: - Assembly

    /// Accumulates the attributed string, the plain text and the tints together,
    /// so a caller cannot append to one and forget another.
    private final class Builder {
        private let theme: Theme
        private let attributed = NSMutableAttributedString()
        private var tints: [Tint] = []

        init(theme: Theme) { self.theme = theme }

        var length: Int { attributed.length }

        func append(_ bytes: ArraySlice<UInt8>, color: CGColor, bold: Bool = false) {
            guard !bytes.isEmpty else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            guard !text.isEmpty else { return }
            attributed.append(
                NSAttributedString(
                    string: text,
                    attributes: [
                        AttributedBuilder.fontKey: bold ? theme.monoBold : theme.mono,
                        AttributedBuilder.colorKey: color,
                    ]
                )
            )
        }

        func tint(from start: Int, color: CGColor, fullWidth: Bool) {
            guard attributed.length > start else { return }
            tints.append(
                Tint(
                    range: NSRange(location: start, length: attributed.length - start),
                    color: color,
                    fullWidth: fullWidth
                )
            )
        }

        func finish() -> CodeText {
            CodeText(attributed: attributed, text: attributed.string, tints: tints)
        }
    }
}
