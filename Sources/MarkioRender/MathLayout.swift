import AppKit
import CoreText

/// Turns a parsed formula into positioned glyphs and rules.
///
/// Every distance here is a fraction of the base font's size, so a formula
/// scales with the text and needs no per-theme tuning. The numbers are the
/// proportions TeX uses, rounded to something a reader would not be able to tell
/// apart from them at reading size.
enum MathLayout {
    /// A serif face, the size of the surrounding text, in upright and italic.
    ///
    /// Mathematics is set in a serif face even where the prose around it is not:
    /// the sans-serif `l`, `1` and `I` are the same stroke, and a formula is
    /// exactly where that costs a reader something.
    struct Context {
        let size: CGFloat
        let color: CGColor
        let variant: MathVariant
        /// `$$…$$`: the limits of a sum go above and below its sign.
        let display: Bool
        let upright: CTFont
        let italic: CTFont

        init(
            size: CGFloat,
            color: CGColor,
            variant: MathVariant = .normal,
            display: Bool = false
        ) {
            self.size = size
            self.color = color
            self.variant = variant
            self.display = display
            upright = Context.face(size: size, variant: variant, italic: false)
            italic = Context.face(size: size, variant: variant, italic: true)
        }

        /// A context for scripts: the same faces, smaller. Display style stops
        /// at the first script, the way it does in TeX — a sum inside an
        /// exponent writes its limits beside it.
        func scaled(_ factor: CGFloat) -> Context {
            Context(size: max(6, size * factor), color: color, variant: variant)
        }

        func styled(_ variant: MathVariant) -> Context {
            Context(size: size, color: color, variant: variant, display: display)
        }

        func font(for kind: MathClass) -> CTFont {
            switch variant {
            case .upright, .sansSerif, .monospace: return upright
            case .italic: return italic
            case .normal, .bold: return kind == .variable ? italic : upright
            }
        }

        /// Serif by default, because the sans-serif `l`, `1` and `I` are one
        /// stroke and a formula is exactly where that costs a reader something.
        /// `\mathsf` and `\mathtt` are the author asking for something else.
        private static func face(size: CGFloat, variant: MathVariant, italic: Bool) -> CTFont {
            var font: NSFont
            switch variant {
            case .monospace:
                font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case .sansSerif:
                font = NSFont.systemFont(ofSize: size)
            default:
                let system = NSFont.systemFont(ofSize: size)
                font = system
                if let descriptor = system.fontDescriptor.withDesign(.serif),
                    let serif = NSFont(descriptor: descriptor, size: size)
                {
                    font = serif
                }
            }
            var traits: CTFontSymbolicTraits = []
            if italic { traits.insert(.traitItalic) }
            if variant == .bold { traits.insert(.traitBold) }
            guard !traits.isEmpty else { return font as CTFont }
            return CTFontCreateCopyWithSymbolicTraits(font as CTFont, size, nil, traits, traits)
                ?? font as CTFont
        }
    }

    static func box(_ node: MathNode, size: CGFloat, color: CGColor, display: Bool = false)
        -> MathBox
    {
        layout(node, in: Context(size: size, color: color, display: display))
    }

    private static func layout(_ node: MathNode, in context: Context) -> MathBox {
        switch node {
        case .empty:
            return empty(in: context)
        case .space(let ems):
            return MathBox(
                items: [], width: ems * context.size, ascent: 0, descent: 0, color: context.color)
        case .atom(let text, let kind):
            return atom(text, kind: kind, in: context)
        case .row(let children):
            return row(children, in: context)
        case .scripted(let base, let sup, let sub):
            return scripted(base: base, sup: sup, sub: sub, in: context)
        case .fraction(let numerator, let denominator):
            return fraction(numerator, denominator, in: context)
        case .radical(let body, let degree):
            return radical(body, degree: degree, in: context)
        case .accented(let body, let mark):
            return accented(body, mark: mark, in: context)
        case .styled(let body, let variant):
            return layout(body, in: context.styled(variant))
        case .grid(let grid):
            return self.grid(grid, in: context)
        }
    }

    private static func empty(in context: Context) -> MathBox {
        MathBox(items: [], width: 0, ascent: 0, descent: 0, color: context.color)
    }

    // MARK: Pieces

    private static func atom(_ text: String, kind: MathClass, in context: Context) -> MathBox {
        // A sum sign is drawn above its own text size, the way it is in print;
        // everything else is set at the size of the prose around it.
        let font =
            kind == .large
            ? CTFontCreateCopyWithAttributes(context.upright, context.size * 1.35, nil, nil)
            : context.font(for: kind)
        let line = self.line(text, font: font, color: context.color)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return MathBox(
            items: [.glyphs(line, origin: .zero)],
            width: width,
            ascent: ascent,
            descent: descent,
            color: context.color
        )
    }

    private static func row(_ children: [MathNode], in context: Context) -> MathBox {
        var items: [MathBox.Item] = []
        var x: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var previous: MathClass?
        for child in children {
            var kind = spacingClass(child)
            // A `-` with nothing to its left is a sign, not a subtraction, and a
            // sign hugs what it negates.
            if kind == .binary, previous == nil || previous == .binary || previous == .relation {
                kind = .ordinary
            }
            x += gap(previous, kind, size: context.size)
            let box = layout(child, in: context)
            items.append(contentsOf: box.moved(dx: x, dy: 0))
            x += box.width
            ascent = max(ascent, box.ascent)
            descent = max(descent, box.descent)
            previous = kind
        }
        return MathBox(
            items: items, width: x, ascent: ascent, descent: descent, color: context.color)
    }

    private static func scripted(
        base: MathNode, sup: MathNode?, sub: MathNode?, in context: Context
    ) -> MathBox {
        if context.display, takesLimits(base) {
            return limits(base: base, above: sup, below: sub, in: context)
        }
        let baseBox = layout(base, in: context)
        let small = context.scaled(0.7)
        var items = baseBox.items
        var ascent = baseBox.ascent
        var descent = baseBox.descent
        var width = baseBox.width
        let kern = context.size * 0.04

        if let sup {
            let box = layout(sup, in: small)
            // High enough to clear the base's own body, never so high that the
            // line grows around a lone `x²`.
            let shift = max(context.size * 0.42, baseBox.ascent * 0.62)
            items += box.moved(dx: baseBox.width + kern, dy: -shift)
            ascent = max(ascent, shift + box.ascent)
            descent = max(descent, box.descent - shift)
            width = max(width, baseBox.width + kern + box.width)
        }
        if let sub {
            let shift = max(context.size * 0.2, baseBox.descent + context.size * 0.08)
            let box = layout(sub, in: small)
            items += box.moved(dx: baseBox.width + kern, dy: shift)
            descent = max(descent, shift + box.descent)
            ascent = max(ascent, box.ascent - shift)
            width = max(width, baseBox.width + kern + box.width)
        }
        return MathBox(
            items: items, width: width, ascent: ascent, descent: descent, color: context.color)
    }

    /// Whether a symbol writes its scripts above and below itself in display
    /// style. A sum does; an integral does not, because its limits are read
    /// along its own slope and a book sets them beside it.
    private static func takesLimits(_ node: MathNode) -> Bool {
        switch node {
        case .atom(let text, .large):
            return !integrals.contains(text)
        case .atom(let text, .function):
            return limitFunctions.contains(text)
        case .styled(let inner, _):
            return takesLimits(inner)
        default:
            return false
        }
    }

    private static let integrals: Set<String> = ["∫", "∬", "∮"]
    private static let limitFunctions: Set<String> = [
        "lim", "limsup", "liminf", "max", "min", "sup", "inf", "gcd", "det",
    ]

    /// A sum with its range written over and under the sign.
    private static func limits(
        base: MathNode, above: MathNode?, below: MathNode?, in context: Context
    ) -> MathBox {
        let signBox = layout(base, in: context)
        let small = context.scaled(0.7)
        let gap = context.size * 0.14
        let topBox = above.map { layout($0, in: small) }
        let bottomBox = below.map { layout($0, in: small) }
        let width = max(signBox.width, max(topBox?.width ?? 0, bottomBox?.width ?? 0))

        var items = signBox.moved(dx: (width - signBox.width) / 2, dy: 0)
        var ascent = signBox.ascent
        var descent = signBox.descent
        if let topBox {
            // Against the sign's ink, not its font's ascent, for the same reason
            // an accent is: the room a font leaves above ∑ is not part of ∑.
            let y = inkTop(of: signBox) - gap - topBox.descent
            items += topBox.moved(dx: (width - topBox.width) / 2, dy: y)
            ascent = max(ascent, -y + topBox.ascent)
        }
        if let bottomBox {
            let y = inkBottom(of: signBox) + gap + bottomBox.ascent
            items += bottomBox.moved(dx: (width - bottomBox.width) / 2, dy: y)
            descent = max(descent, y + bottomBox.descent)
        }
        return MathBox(
            items: items, width: width, ascent: ascent, descent: descent, color: context.color)
    }

    private static func fraction(
        _ numerator: MathNode, _ denominator: MathNode, in context: Context
    ) -> MathBox {
        let small = context.scaled(0.92)
        let top = layout(numerator, in: small)
        let bottom = layout(denominator, in: small)
        // The bar sits on the maths axis — roughly the height of a minus sign —
        // so `a/b` lines up with the `=` beside it instead of with the baseline.
        let axis = context.size * 0.28
        let thickness = max(1, (context.size * 0.045).rounded())
        let gap = context.size * 0.18
        let padding = context.size * 0.12
        let width = max(top.width, bottom.width) + padding * 2

        let topY = -axis - thickness / 2 - gap - top.descent
        let bottomY = -axis + thickness / 2 + gap + bottom.ascent
        var items = top.moved(dx: (width - top.width) / 2, dy: topY)
        items += bottom.moved(dx: (width - bottom.width) / 2, dy: bottomY)
        items.append(
            .rule(
                CGRect(
                    x: padding / 2,
                    y: -axis - thickness / 2,
                    width: width - padding,
                    height: thickness
                )
            )
        )
        return MathBox(
            items: items,
            width: width,
            ascent: -topY + top.ascent,
            descent: bottomY + bottom.descent,
            color: context.color
        )
    }

    /// A block of rows and columns, centred on the maths axis and wrapped in
    /// brackets grown to its height.
    private static func grid(_ grid: MathGrid, in context: Context) -> MathBox {
        let cells = grid.rows.map { row in row.map { layout($0, in: context) } }
        let columns = cells.map(\.count).max() ?? 0
        guard columns > 0 else { return empty(in: context) }
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in cells {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], cell.width)
            }
        }
        // `&` in an aligned block is the point the lines line up at, not a
        // gap between columns; in a matrix it is a gap.
        let columnGap = context.size * (grid.style == .alternating ? 0.16 : 0.7)
        let rowGap = context.size * 0.35
        let axis = context.size * 0.28

        var heights: [(ascent: CGFloat, descent: CGFloat)] = []
        for row in cells {
            heights.append(
                (row.map(\.ascent).max() ?? 0, row.map(\.descent).max() ?? 0)
            )
        }
        let total =
            heights.reduce(0) { $0 + $1.ascent + $1.descent }
            + rowGap * CGFloat(max(0, cells.count - 1))
        let body = widths.reduce(0, +) + columnGap * CGFloat(columns - 1)

        // The block hangs either side of the axis, so a one-row matrix sits
        // exactly where a fraction of the same height would.
        var y = -total / 2 - axis + (heights.first?.ascent ?? 0)
        var items: [MathBox.Item] = []
        for (index, row) in cells.enumerated() {
            var x: CGFloat = 0
            for (column, cell) in row.enumerated() {
                let slack = widths[column] - cell.width
                let offset: CGFloat
                switch grid.style {
                case .centred: offset = slack / 2
                case .left: offset = 0
                case .alternating: offset = column % 2 == 0 ? slack : 0
                }
                items += cell.moved(dx: x + offset, dy: y)
                x += widths[column] + columnGap
            }
            if index + 1 < cells.count {
                y += heights[index].descent + rowGap + heights[index + 1].ascent
            }
        }
        var ascent = total / 2 + axis
        var descent = total / 2 - axis
        var width = body
        // Brackets are one glyph grown by size, the same trick the radical uses.
        if let left = grid.left {
            let bracket = self.bracket(left, height: total, in: context)
            items = bracket.box.moved(dx: 0, dy: 0) + items.map { move($0, dx: bracket.box.width) }
            width += bracket.box.width
            ascent = max(ascent, bracket.box.ascent)
            descent = max(descent, bracket.box.descent)
        }
        if let right = grid.right {
            let bracket = self.bracket(right, height: total, in: context)
            items += bracket.box.moved(dx: width, dy: 0)
            width += bracket.box.width
            ascent = max(ascent, bracket.box.ascent)
            descent = max(descent, bracket.box.descent)
        }
        return MathBox(
            items: items, width: width, ascent: ascent, descent: descent, color: context.color)
    }

    /// A bracket scaled to a height, measured by its ink so it really covers
    /// what it encloses.
    private static func bracket(_ text: String, height: CGFloat, in context: Context) -> (
        box: MathBox, width: CGFloat
    ) {
        let probe = line(text, font: context.upright, color: context.color)
        let natural = max(1, CTLineGetBoundsWithOptions(probe, .useGlyphPathBounds).height)
        let scale = min(4, max(1, height / natural))
        let font = CTFontCreateCopyWithAttributes(context.upright, context.size * scale, nil, nil)
        let glyph = line(text, font: font, color: context.color)
        let ink = CTLineGetBoundsWithOptions(glyph, .useGlyphPathBounds)
        let width = CGFloat(CTLineGetTypographicBounds(glyph, nil, nil, nil))
        let axis = context.size * 0.28
        // Centred on the axis, like the block it wraps.
        let baseline = height / 2 - axis - (ink.height - ink.maxY)
        let box = MathBox(
            items: [.glyphs(glyph, origin: CGPoint(x: 0, y: baseline))],
            width: width,
            ascent: -(baseline - ink.maxY),
            descent: baseline - ink.minY,
            color: context.color
        )
        return (box, width)
    }

    private static func move(_ item: MathBox.Item, dx: CGFloat) -> MathBox.Item {
        switch item {
        case .glyphs(let line, let origin):
            return .glyphs(line, origin: CGPoint(x: origin.x + dx, y: origin.y))
        case .rule(let rect):
            return .rule(rect.offsetBy(dx: dx, dy: 0))
        }
    }

    /// A mark over or under what it belongs to.
    ///
    /// A bar is a rule rather than a macron: a font's macron is one letter wide,
    /// and `\overline{AB}` has to cover both.
    private static func accented(_ body: MathNode, mark: MathAccent, in context: Context)
        -> MathBox
    {
        let content = layout(body, in: context)
        let thickness = max(1, (context.size * 0.045).rounded())
        let gap = context.size * 0.1
        var items = content.items
        var ascent = content.ascent
        var descent = content.descent
        // Marks are placed against the *ink*, not the font's ascent. A hat over
        // an `x` set at the font's ascent floats a whole x-height clear of the
        // letter it belongs to.
        switch mark {
        case .bar:
            let y = inkTop(of: content) - gap - thickness
            items.append(.rule(CGRect(x: 0, y: y, width: content.width, height: thickness)))
            ascent = max(ascent, -y)
        case .underline:
            let y = inkBottom(of: content) + gap
            items.append(.rule(CGRect(x: 0, y: y, width: content.width, height: thickness)))
            descent = max(descent, y + thickness)
        default:
            let glyph = line(
                MathSymbols.accent(mark),
                font: CTFontCreateCopyWithAttributes(
                    context.upright, context.size * (mark == .arrow ? 0.6 : 1), nil, nil),
                color: context.color
            )
            let ink = CTLineGetBoundsWithOptions(glyph, .useGlyphPathBounds)
            let width = CGFloat(CTLineGetTypographicBounds(glyph, nil, nil, nil))
            let baseline = inkTop(of: content) - gap + ink.minY
            items.append(
                .glyphs(glyph, origin: CGPoint(x: (content.width - width) / 2, y: baseline)))
            ascent = max(ascent, -(baseline - ink.maxY))
        }
        return MathBox(
            items: items,
            width: content.width,
            ascent: ascent,
            descent: descent,
            color: context.color
        )
    }

    private static func radical(_ body: MathNode, degree: MathNode?, in context: Context)
        -> MathBox
    {
        let content = layout(body, in: context)
        let thickness = max(1, (context.size * 0.045).rounded())
        let gap = context.size * 0.14
        let height = content.ascent + content.descent + gap + thickness

        // The sign is one glyph stretched by size rather than a drawn path: a
        // font's radical already has the right stroke weight, and a path would
        // have to guess it.
        //
        // Everything about it is measured from the *ink*, not from the font's
        // ascent and descent. A font leaves room above its tallest glyph, and
        // measuring that room instead of the stroke both shrinks the sign and
        // floats the bar above the arm it is supposed to continue.
        let probe = line("√", font: context.upright, color: context.color)
        let natural = max(1, CTLineGetBoundsWithOptions(probe, .useGlyphPathBounds).height)
        let scale = min(3, max(1, height / natural))
        let font = CTFontCreateCopyWithAttributes(context.upright, context.size * scale, nil, nil)
        let sign = line("√", font: font, color: context.color)
        let ink = CTLineGetBoundsWithOptions(sign, .useGlyphPathBounds)
        let signWidth = CGFloat(CTLineGetTypographicBounds(sign, nil, nil, nil))

        // Ink bounds are y-up around the baseline; the box is y-down. Sit the
        // sign's foot at the content's own depth, and start the bar where its
        // arm ends, so the two read as one stroke.
        let signBaseline = content.descent + ink.minY
        let top = signBaseline - ink.maxY
        // A degree sits in the crook, over the sign's short arm, and pushes the
        // whole root right when it is wider than the crook can hold.
        var degreeBox: MathBox?
        var shift: CGFloat = 0
        if let degree {
            let box = layout(degree, in: context.scaled(0.55))
            degreeBox = box
            shift = max(0, box.width - signWidth * 0.55)
        }
        var items: [MathBox.Item] = [
            .glyphs(sign, origin: CGPoint(x: shift, y: signBaseline))
        ]
        if let degreeBox {
            items += degreeBox.moved(
                dx: max(0, shift + signWidth * 0.2 - degreeBox.width / 2),
                dy: top + degreeBox.height * 0.9
            )
        }
        items += content.moved(dx: shift + signWidth, dy: 0)
        items.append(
            .rule(
                CGRect(
                    x: shift + signWidth - thickness / 2,
                    y: top,
                    width: content.width + thickness / 2,
                    height: thickness
                )
            )
        )
        return MathBox(
            items: items,
            width: shift + signWidth + content.width,
            ascent: max(content.ascent, -top),
            descent: content.descent,
            color: context.color
        )
    }

    /// The topmost ink in a box, in the box's own coordinates. Falls back to the
    /// declared ascent for a box that draws nothing.
    private static func inkTop(of box: MathBox) -> CGFloat {
        var top = CGFloat.greatestFiniteMagnitude
        for item in box.items {
            switch item {
            case .glyphs(let line, let origin):
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                top = min(top, origin.y - ink.maxY)
            case .rule(let rect):
                top = min(top, rect.minY)
            }
        }
        return top == .greatestFiniteMagnitude ? -box.ascent : top
    }

    private static func inkBottom(of box: MathBox) -> CGFloat {
        var bottom = -CGFloat.greatestFiniteMagnitude
        for item in box.items {
            switch item {
            case .glyphs(let line, let origin):
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                bottom = max(bottom, origin.y - ink.minY)
            case .rule(let rect):
                bottom = max(bottom, rect.maxY)
            }
        }
        return bottom == -CGFloat.greatestFiniteMagnitude ? box.descent : bottom
    }

    // MARK: Spacing

    private static func spacingClass(_ node: MathNode) -> MathClass {
        switch node {
        case .atom(_, let kind): return kind
        case .scripted(let base, _, _): return spacingClass(base)
        case .accented(let base, _): return spacingClass(base)
        case .grid: return .ordinary
        case .styled(let base, _): return spacingClass(base)
        default: return .ordinary
        }
    }

    private static func gap(_ left: MathClass?, _ right: MathClass, size: CGFloat) -> CGFloat {
        guard let left else { return 0 }
        if left == .relation || right == .relation { return size * 0.28 }
        if left == .binary || right == .binary { return size * 0.22 }
        if left == .punctuation { return size * 0.16 }
        if left == .function { return size * 0.16 }
        if left == .large || right == .large { return size * 0.12 }
        if left == .text || right == .text { return size * 0.16 }
        return 0
    }

    private static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    AttributedBuilder.fontKey: font,
                    AttributedBuilder.colorKey: color,
                ]
            )
        )
    }
}
