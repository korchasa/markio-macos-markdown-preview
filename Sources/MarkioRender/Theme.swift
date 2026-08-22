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
        /// Base body size in points; every other size is derived from it, and
        /// this is the size a zoom of 1 means.
        ///
        /// Larger than the 13 points macOS sets its interface in: that size is
        /// for labels and menus read a word at a time, and this is a page read
        /// for minutes at a stretch.
        public var bodySize: CGFloat = 15
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
        /// How much larger than the default everything here has been made.
        ///
        /// Kept beside the sizes rather than derived from `bodySize`, because
        /// the fonts a theme builds outside that scale — the control label —
        /// need the factor too, and a reader who has zoomed twice should get
        /// the same numbers as one who zoomed once by the product.
        public private(set) var zoom: CGFloat = 1

        public init() {}

        /// The same measurements at a different size: type, spacing, indents
        /// and rules together.
        ///
        /// Scaling the type alone gives a page with the letters of one size and
        /// the margins of another, which reads as a bug long before anybody can
        /// name it. Line thickness is included and floored at a device pixel:
        /// a rule that scales below one is a rule that vanishes.
        public func scaled(by factor: CGFloat) -> Metrics {
            guard factor > 0 else { return self }
            var copy = self
            copy.bodySize *= factor
            copy.paragraphSpacing *= factor
            copy.headingSpacingBefore *= factor
            copy.headingSpacingAfter *= factor
            copy.listIndent *= factor
            copy.quoteIndent *= factor
            copy.quoteBarWidth *= factor
            copy.codePadding *= factor
            copy.codeCornerRadius *= factor
            copy.tableCellPadding *= factor
            copy.ruleThickness = max(0.5, copy.ruleThickness * factor)
            copy.blockSpacingTight *= factor
            copy.zoom *= factor
            return copy
        }
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
        /// Bands behind added and removed lines in a `diff` block.
        public var diffAddedText: CGColor
        public var diffAddedBackground: CGColor
        public var diffRemovedText: CGColor
        public var diffRemovedBackground: CGColor
    }

    public var metrics: Metrics
    public var palette: Palette
    public var isDark: Bool
    /// The colours a diagram tells one thing from another with — pie slices,
    /// branches of a graph, sections of a chart. They live here rather than in
    /// the layout because a Mermaid theme changes them along with the palette.
    public var diagramWheel: [CGColor] = Theme.wheel(named: "default")

    /// Fonts are `CTFont` because that is what the typesetter wants; going
    /// through `NSFont` per run would bridge on every line.
    public var body: CTFont
    public var bodyBold: CTFont
    public var bodyItalic: CTFont
    public var bodyBoldItalic: CTFont
    public var mono: CTFont
    public var monoBold: CTFont
    /// Small label for the controls drawn over the text — the language badge
    /// and the Copy pill on a fenced block.
    public var controlLabel: CTFont
    /// The text of a footnote, set smaller than the prose it belongs to.
    public var footnote: CTFont
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
        controlLabel = Theme.systemFont(size: 11 * metrics.zoom, weight: .medium)
        footnote = Theme.systemFont(size: size * 0.9, weight: .regular)
        // Heading scale, largest first, tuned to stay readable next to the body.
        let scales: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.92]
        headings = scales.map { Theme.systemFont(size: size * $0, weight: .bold) }
    }

    /// The same theme at the reading size, with the reader's zoom taken out.
    ///
    /// A picture drawn for its own sake — enlarged, copied, written to a file —
    /// is the diagram, not the page: how large somebody is reading today should
    /// not decide how many pixels the file has.
    public var unzoomed: Theme { Theme(isDark: isDark) }

    /// The same theme with the colours a diagram is drawn in — a white page,
    /// and ink chosen against it.
    ///
    /// A diagram is a picture made of lines, and lines are the first thing a
    /// dark page takes away: at the reader's own dark palette an outline and
    /// the card behind it differ by a shade nobody can see, which is the grey
    /// on grey a reader complains about. Mermaid's own themes are written for
    /// a white page, and so are the colours authors set by hand — the pastel
    /// `box rgb(...)` of a sequence diagram assumes dark lettering over it. So
    /// the picture gets a white page whatever the page around it is, and the
    /// document stays the reader's.
    public var forDiagrams: Theme {
        var copy = self
        copy.palette = Theme.diagramPalette()
        copy.diagramWheel = Theme.wheel(named: "default")
        return copy
    }

    /// Ink for a white page, at contrasts that hold up: lettering well past
    /// what WCAG asks of text, outlines and connecting lines past what it asks
    /// of everything that is not text. `DiagramContrastTests` is where those
    /// ratios are stated as numbers.
    private static func diagramPalette() -> Palette {
        func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
            CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        }
        var palette = Theme.palette(isDark: false)
        palette.background = color(255, 255, 255)
        palette.codeBackground = color(255, 255, 255)
        palette.text = color(20, 24, 31)
        palette.codeText = color(20, 24, 31)
        // Message labels and the lines they sit over. The light palette's own
        // secondary grey is meant for a paragraph of prose beside black text,
        // not for a word floating over a line.
        palette.secondaryText = color(65, 75, 88)
        // Box outlines, lifelines, arrows. The table border this replaces is a
        // hairline meant to be nearly invisible; a diagram is made of them.
        palette.tableBorder = color(107, 114, 128)
        // What a box is filled with: enough to read as a box against the page,
        // light enough to keep the lettering on it at full contrast.
        palette.tableHeaderBackground = color(237, 240, 245)
        return palette
    }

    /// The same theme repainted in one of Mermaid's own — `default`, `neutral`,
    /// `dark`, `forest` or `base`.
    ///
    /// A diagram that names a theme is asking for particular colours, and
    /// drawing it in the reader's instead would be a picture its author did not
    /// write. Only the diagram is repainted; the page around it stays the
    /// reader's, because the theme was written over a fence, not over the
    /// document. An unknown name gives nil, and the fence stays source.
    public func mermaidThemed(_ name: String) -> Theme? {
        guard let colours = Theme.mermaidPalette(named: name, isDark: isDark) else { return nil }
        var copy = self
        copy.palette = colours
        copy.diagramWheel = Theme.wheel(named: name)
        return copy
    }

    /// The width of a reading column measured in characters, in points.
    ///
    /// The unit is the advance of a digit in the body font — what CSS calls
    /// `ch`. It lives here because every host of the renderer needs it and none
    /// of them should have to typeset a sample glyph to get it.
    public func columnWidth(characters: Int) -> CGFloat {
        let sample = NSAttributedString(
            string: "0",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body]
        )
        let line = CTLineCreateWithAttributedString(sample)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return CGFloat(characters) * max(advance, 6)
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

    /// Mermaid's five built-in themes, as the handful of colours a diagram is
    /// actually drawn from: what a box is filled and outlined with, what its
    /// words are, what a line is, and what shows behind them.
    private static func mermaidPalette(named name: String, isDark: Bool) -> Palette? {
        func color(_ hex: UInt32) -> CGColor {
            CGColor(
                srgbRed: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255, alpha: 1)
        }
        /// fill, stroke, text, line, page.
        let colours: [String: (UInt32, UInt32, UInt32, UInt32, UInt32)] = [
            "default": (0xECEC_FF, 0x9370_DB, 0x1313_11, 0x3333_33, 0xFFFF_FF),
            "base": (0xECEC_FF, 0x9370_DB, 0x1313_11, 0x3333_33, 0xFFFF_FF),
            "neutral": (0xEEEE_EE, 0x9999_99, 0x0000_00, 0x6666_66, 0xFFFF_FF),
            "forest": (0xCDE4_98, 0x1381_4D, 0x0000_00, 0x1381_4D, 0xF4F4_F4),
            "dark": (0x1F20_20, 0x8181_81, 0xF9FF_FE, 0xCCCC_CC, 0x3333_33),
        ]
        guard let picked = colours[name] else { return nil }
        var palette = Theme.palette(isDark: isDark)
        palette.tableHeaderBackground = color(picked.0)
        palette.tableBorder = color(picked.1)
        palette.text = color(picked.2)
        palette.codeText = color(picked.2)
        palette.secondaryText = color(picked.3)
        palette.background = color(picked.4)
        palette.codeBackground = color(picked.4)
        return palette
    }

    /// The wheel each Mermaid theme tells its series apart with.
    private static func wheel(named name: String) -> [CGColor] {
        func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        switch name {
        case "forest":
            return [
                color(0.07, 0.51, 0.30), color(0.55, 0.75, 0.40), color(0.31, 0.65, 0.45),
                color(0.72, 0.80, 0.35), color(0.16, 0.42, 0.36), color(0.45, 0.68, 0.28),
                color(0.10, 0.60, 0.52), color(0.62, 0.72, 0.22),
            ]
        case "dark":
            return [
                color(0.51, 0.62, 0.95), color(0.95, 0.65, 0.35), color(0.45, 0.80, 0.60),
                color(0.92, 0.52, 0.58), color(0.72, 0.62, 0.95), color(0.55, 0.85, 0.88),
                color(0.95, 0.83, 0.42), color(0.75, 0.66, 0.55),
            ]
        case "neutral":
            return [
                color(0.40, 0.40, 0.40), color(0.60, 0.60, 0.60), color(0.28, 0.28, 0.28),
                color(0.72, 0.72, 0.72), color(0.50, 0.50, 0.50), color(0.35, 0.35, 0.35),
                color(0.66, 0.66, 0.66), color(0.22, 0.22, 0.22),
            ]
        default:
            return [
                color(0.30, 0.55, 0.90), color(0.95, 0.60, 0.25), color(0.35, 0.72, 0.50),
                color(0.85, 0.40, 0.45), color(0.60, 0.50, 0.85), color(0.45, 0.75, 0.80),
                color(0.90, 0.75, 0.30), color(0.65, 0.55, 0.45),
            ]
        }
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
                background: color(22, 24, 28),
                diffAddedText: color(150, 226, 165),
                diffAddedBackground: color(30, 74, 44, 0.55),
                diffRemovedText: color(255, 160, 160),
                diffRemovedBackground: color(84, 32, 36, 0.55)
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
            background: color(255, 255, 255),
            diffAddedText: color(20, 92, 44),
            diffAddedBackground: color(198, 240, 208, 0.75),
            diffRemovedText: color(140, 30, 34),
            diffRemovedBackground: color(255, 210, 210, 0.75)
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

extension Theme {
    /// The colour the map draws a stretch of document in.
    ///
    /// Derived from the palette rather than invented, so the two appearances
    /// cannot drift apart the first time either of them is touched: prose and
    /// lists are the text colours faded back, code and quotes are the colours
    /// those blocks already use, and the three kinds a reader hunts for —
    /// diagram, table, picture — borrow the wheel a diagram tells its own parts
    /// apart with.
    public func mapColor(for kind: DocumentMap.Kind) -> CGColor {
        func fade(_ color: CGColor, _ alpha: CGFloat) -> CGColor {
            color.copy(alpha: alpha) ?? color
        }
        func wheel(_ index: Int) -> CGColor {
            guard !diagramWheel.isEmpty else { return palette.link }
            return diagramWheel[index % diagramWheel.count]
        }
        switch kind {
        case .prose: return fade(palette.secondaryText, 0.18)
        case .list: return fade(palette.secondaryText, 0.3)
        case .heading: return fade(palette.text, 0.7)
        case .code: return fade(palette.codeText, 0.38)
        case .quote: return fade(palette.quoteBar, 0.7)
        case .diagram: return fade(wheel(0), 0.85)
        case .table: return fade(wheel(2), 0.85)
        case .picture: return fade(wheel(1), 0.85)
        case .rule: return fade(palette.rule, 0.9)
        }
    }
}
