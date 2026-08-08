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
        let upright: CTFont
        let italic: CTFont

        init(size: CGFloat, color: CGColor) {
            self.size = size
            self.color = color
            upright = Context.serif(size: size, italic: false)
            italic = Context.serif(size: size, italic: true)
        }

        /// A context for scripts: the same faces, smaller.
        func scaled(_ factor: CGFloat) -> Context {
            Context(size: max(6, size * factor), color: color)
        }

        func font(for kind: MathClass) -> CTFont {
            kind == .variable ? italic : upright
        }

        private static func serif(size: CGFloat, italic: Bool) -> CTFont {
            let system = NSFont.systemFont(ofSize: size)
            var font = system
            if let descriptor = system.fontDescriptor.withDesign(.serif),
                let serif = NSFont(descriptor: descriptor, size: size)
            {
                font = serif
            }
            guard italic else { return font as CTFont }
            return CTFontCreateCopyWithSymbolicTraits(
                font as CTFont, size, nil, .traitItalic, .traitItalic) ?? font as CTFont
        }
    }

    static func box(_ node: MathNode, size: CGFloat, color: CGColor) -> MathBox {
        layout(node, in: Context(size: size, color: color))
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
        case .radical(let body):
            return radical(body, in: context)
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

    private static func radical(_ body: MathNode, in context: Context) -> MathBox {
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
        var items: [MathBox.Item] = [.glyphs(sign, origin: CGPoint(x: 0, y: signBaseline))]
        items += content.moved(dx: signWidth, dy: 0)
        items.append(
            .rule(
                CGRect(
                    x: signWidth - thickness / 2,
                    y: top,
                    width: content.width + thickness / 2,
                    height: thickness
                )
            )
        )
        return MathBox(
            items: items,
            width: signWidth + content.width,
            ascent: max(content.ascent, -top),
            descent: content.descent,
            color: context.color
        )
    }

    // MARK: Spacing

    private static func spacingClass(_ node: MathNode) -> MathClass {
        switch node {
        case .atom(_, let kind): return kind
        case .scripted(let base, _, _): return spacingClass(base)
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
