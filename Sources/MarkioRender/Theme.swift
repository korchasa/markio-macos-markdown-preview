import AppKit
import CoreText

/// Fonts, colours and spacing for the rendered document.
///
/// Every value is resolved once per appearance change and then handed to
/// CoreText as a concrete font and `CGColor`. Resolving inside the draw loop
/// would mean asking AppKit for a dynamic colour thousands of times a scroll.
/// Not `Sendable`: `CTFont` and `CGColor` are Core Foundation types tied to
/// the drawing context, and the theme only ever crosses the main actor.
public struct Theme {
    public struct Metrics: Sendable {
        /// Base body size in points; every other size is derived from it.
        public var bodySize: CGFloat = 14
        public var lineHeightMultiple: CGFloat = 1.55
        public var paragraphSpacing: CGFloat = 12
        public var headingSpacingBefore: CGFloat = 24
        public var headingSpacingAfter: CGFloat = 8
        public var listIndent: CGFloat = 26
        public var quoteIndent: CGFloat = 20
        public var quoteBarWidth: CGFloat = 3
        public var codePadding: CGFloat = 12
        public var codeCornerRadius: CGFloat = 6
        public var tableCellPadding: CGFloat = 7
        public var ruleThickness: CGFloat = 1
        public var blockSpacingTight: CGFloat = 3

        public init() {}
    }

    public struct Palette {
        public var text: CGColor
        public var secondaryText: CGColor
        public var link: CGColor
        public var codeText: CGColor
        public var codeBackground: CGColor
        public var inlineCodeBackground: CGColor
        public var quoteBar: CGColor
        public var rule: CGColor
        public var tableBorder: CGColor
        public var tableHeaderBackground: CGColor
        public var highlightBackground: CGColor
        public var keyboardBackground: CGColor
        public var findMatch: CGColor
        public var findCurrentMatch: CGColor
        public var selection: CGColor
        public var background: CGColor
    }

    public var metrics: Metrics
    public var palette: Palette
    public var isDark: Bool

    /// Fonts are `CTFont` because that is what the typesetter wants; going
    /// through `NSFont` per run would bridge on every line.
    public var body: CTFont
    public var bodyBold: CTFont
    public var bodyItalic: CTFont
    public var bodyBoldItalic: CTFont
    public var mono: CTFont
    public var monoBold: CTFont
    public var headings: [CTFont]

    public init(isDark: Bool, metrics: Metrics = Metrics()) {
        self.metrics = metrics
        self.isDark = isDark
        self.palette = Theme.palette(isDark: isDark)

        let size = metrics.bodySize
        body = Theme.systemFont(size: size, weight: .regular)
        bodyBold = Theme.systemFont(size: size, weight: .semibold)
        bodyItalic = Theme.italic(Theme.systemFont(size: size, weight: .regular))
        bodyBoldItalic = Theme.italic(Theme.systemFont(size: size, weight: .semibold))
        mono = Theme.monoFont(size: size * 0.92, weight: .regular)
        monoBold = Theme.monoFont(size: size * 0.92, weight: .bold)
        // Heading scale, largest first, tuned to stay readable next to 14 pt body.
        let scales: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.92]
        headings = scales.map { Theme.systemFont(size: size * $0, weight: .bold) }
    }

    public func heading(level: Int) -> CTFont {
        headings[max(0, min(headings.count - 1, level - 1))]
    }

    /// The font for a run's cumulative style. Code wins over emphasis because a
    /// code span inside bold text is still code.
    public func font(for style: InlineStyleMask) -> CTFont {
        if style.contains(.monospaced) {
            return style.contains(.bold) ? monoBold : mono
        }
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): return bodyBoldItalic
        case (true, false): return bodyBold
        case (false, true): return bodyItalic
        case (false, false): return body
        }
    }

    public var lineHeight: CGFloat {
        (CTFontGetAscent(body) + CTFontGetDescent(body) + CTFontGetLeading(body))
            * metrics.lineHeightMultiple
    }

    public var monoLineHeight: CGFloat {
        (CTFontGetAscent(mono) + CTFontGetDescent(mono) + CTFontGetLeading(mono)) * 1.45
    }

    // MARK: - Construction helpers

    private static func systemFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }

    private static func monoFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
    }

    private static func italic(_ font: CTFont) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) ?? font
    }

    private static func palette(isDark: Bool) -> Palette {
        func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1)
            -> CGColor
        {
            CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
        }
        if isDark {
            return Palette(
                text: color(230, 232, 236),
                secondaryText: color(150, 156, 166),
                link: color(96, 165, 250),
                codeText: color(220, 224, 232),
                codeBackground: color(30, 33, 39),
                inlineCodeBackground: color(52, 57, 66),
                quoteBar: color(72, 78, 88),
                rule: color(58, 63, 72),
                tableBorder: color(60, 65, 75),
                tableHeaderBackground: color(38, 42, 50),
                highlightBackground: color(120, 96, 20),
                keyboardBackground: color(56, 61, 70),
                findMatch: color(140, 116, 30),
                findCurrentMatch: color(214, 148, 20),
                selection: color(38, 92, 158, 0.55),
                background: color(22, 24, 28)
            )
        }
        return Palette(
            text: color(28, 32, 38),
            secondaryText: color(106, 114, 126),
            link: color(20, 100, 200),
            codeText: color(36, 41, 47),
            codeBackground: color(246, 247, 249),
            inlineCodeBackground: color(233, 236, 240),
            quoteBar: color(210, 214, 220),
            rule: color(224, 228, 233),
            tableBorder: color(214, 219, 225),
            tableHeaderBackground: color(246, 247, 249),
            highlightBackground: color(255, 235, 140),
            keyboardBackground: color(240, 242, 245),
            findMatch: color(255, 226, 120),
            findCurrentMatch: color(255, 176, 40),
            selection: color(160, 200, 255, 0.75),
            background: color(255, 255, 255)
        )
    }
}

/// The subset of inline style that decides which font a run gets.
public struct InlineStyleMask: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = InlineStyleMask(rawValue: 1 << 0)
    public static let italic = InlineStyleMask(rawValue: 1 << 1)
    public static let monospaced = InlineStyleMask(rawValue: 1 << 2)
}
