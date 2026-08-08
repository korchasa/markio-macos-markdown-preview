import AppKit
import CoreText

/// A formula, set with real glyphs instead of shown as its own source.
///
/// This is a small typesetter for the LaTeX people actually write in prose:
/// letters and numbers, Greek, the common operators and relations, scripts,
/// fractions and roots. It is deliberately not a LaTeX engine — there are no
/// macros, no environments, no alignment. Anything it does not understand makes
/// `parse` return nil, and the caller falls back to showing the source, which is
/// what the viewer did before this existed and is never wrong, only unhelpful.
///
/// Everything here is measured in the base font's size, so a formula grows and
/// shrinks with the text around it and sits on the same baseline.
enum MathFormula {
    /// Carries the laid-out formula from the attributed string to the block that
    /// draws it — the same trick inline pictures use.
    static let key = NSAttributedString.Key("markio.math")

    /// Whether this source can be typeset.
    ///
    /// Font-free on purpose: `BlockPlainText` asks the same question on a
    /// background queue with no theme and no window, and its answer has to match
    /// what is drawn character for character, or Find highlights the wrong word.
    static func canTypeset(_ source: String) -> Bool {
        MathParser.parse(source) != nil
    }

    /// Lay a formula out around the baseline, or say it cannot be done.
    ///
    /// Fails only where `canTypeset` fails: once the source parses, laying it out
    /// always succeeds.
    static func box(source: String, base: CTFont, color: CGColor) -> MathBox? {
        guard let node = MathParser.parse(source) else { return nil }
        return MathLayout.box(node, size: CTFontGetSize(base), color: color)
    }

    /// A delegate that makes CoreText leave exactly the formula's room on the
    /// line. Without it the glyphs would be drawn over the text after them.
    static func delegate(box: MathBox) -> CTRunDelegate? {
        let metrics = UnsafeMutablePointer<CGSize>.allocate(capacity: 2)
        // Two points rather than a bespoke struct: a run-delegate callback is a C
        // function pointer and cannot capture, so the values have to travel in
        // memory the callbacks can name blindly.
        metrics[0] = CGSize(width: box.width, height: box.ascent)
        metrics[1] = CGSize(width: 0, height: box.descent)
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self).deallocate()
            },
            getAscent: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self)[0].height
            },
            getDescent: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self)[1].height
            },
            getWidth: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self)[0].width
            }
        )
        return CTRunDelegateCreate(&callbacks, metrics)
    }
}

/// A laid-out formula: glyph runs and rules, positioned around its own baseline.
///
/// Coordinates match the rest of the renderer — x grows right, y grows *down*,
/// and the origin is the baseline at the formula's left edge. A superscript
/// therefore has a negative y, which is the same flip that lets block offsets be
/// read straight out of the height index.
final class MathBox {
    enum Item {
        case glyphs(CTLine, origin: CGPoint)
        case rule(CGRect)
    }

    let items: [Item]
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let color: CGColor

    var height: CGFloat { ascent + descent }

    init(items: [Item], width: CGFloat, ascent: CGFloat, descent: CGFloat, color: CGColor) {
        self.items = items
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.color = color
    }

    func moved(dx: CGFloat, dy: CGFloat) -> [Item] {
        items.map { item in
            switch item {
            case .glyphs(let line, let origin):
                return .glyphs(line, origin: CGPoint(x: origin.x + dx, y: origin.y + dy))
            case .rule(let rect):
                return .rule(rect.offsetBy(dx: dx, dy: dy))
            }
        }
    }
}

// MARK: - The tree

/// What a piece of a formula is, which is what decides the space around it.
///
/// TeX calls these classes, and they are the reason `a+b` breathes and `f(x)`
/// does not. Getting them wrong does not break anything — it just makes the
/// formula look like a word with punctuation in it.
enum MathClass {
    case ordinary
    /// A letter, set in italic the way mathematics sets its variables.
    case variable
    /// `+`, `-`, `×`: space on both sides, unless it is a sign rather than an
    /// operation.
    case binary
    /// `=`, `<`, `→`: more space on both sides.
    case relation
    case punctuation
    /// A bracket, which takes no extra space of its own.
    case delimiter
    /// `∑`, `∫`: drawn larger than the text around it.
    case large
    /// `sin`, `log`: upright, with a thin space before its argument.
    case function
    /// Words from `\text{…}`, set upright and spaced as written.
    case text
}

indirect enum MathNode {
    case row([MathNode])
    case atom(String, MathClass)
    case scripted(base: MathNode, sup: MathNode?, sub: MathNode?)
    case fraction(MathNode, MathNode)
    case radical(MathNode)
    /// Explicit space, in ems.
    case space(CGFloat)
    case empty
}

// MARK: - Parsing

struct MathParser {
    private let chars: [Character]
    private var index = 0

    private init(_ source: String) {
        chars = Array(source)
    }

    /// The formula as a tree, or nil when anything in it is beyond this
    /// typesetter. Nil is a promise to the caller, not a failure: it means the
    /// source will be shown instead, so a half-drawn formula never reaches a
    /// reader.
    static func parse(_ source: String) -> MathNode? {
        var parser = MathParser(source)
        guard let row = parser.parseRow(insideGroup: false) else { return nil }
        guard parser.index >= parser.chars.count else { return nil }
        if case .row(let items) = row, items.isEmpty { return nil }
        return row
    }

    private mutating func parseRow(insideGroup: Bool) -> MathNode? {
        var items: [MathNode] = []
        while true {
            skipSpaces()
            guard index < chars.count else { break }
            let char = chars[index]
            if char == "}" {
                // The group's own closing brace is consumed by whoever opened
                // it; a brace with no group is a formula this cannot read.
                return insideGroup ? .row(items) : nil
            }
            if char == "^" || char == "_" {
                index += 1
                guard let argument = parseAtom() else { return nil }
                let base = items.popLast() ?? .empty
                guard let scripted = attach(argument, to: base, raised: char == "^") else {
                    return nil
                }
                items.append(scripted)
                continue
            }
            guard let atom = parseAtom() else { return nil }
            items.append(atom)
        }
        // Running out of input inside a group means the brace was never closed.
        return insideGroup ? nil : .row(items)
    }

    /// Hang a script on a base, keeping the one it may already carry.
    private func attach(_ argument: MathNode, to base: MathNode, raised: Bool) -> MathNode? {
        guard case .scripted(let inner, let sup, let sub) = base else {
            return raised
                ? .scripted(base: base, sup: argument, sub: nil)
                : .scripted(base: base, sup: nil, sub: argument)
        }
        // `x^2^3` has no meaning, and inventing one would draw something the
        // author never wrote.
        if raised, sup != nil { return nil }
        if !raised, sub != nil { return nil }
        return raised
            ? .scripted(base: inner, sup: argument, sub: sub)
            : .scripted(base: inner, sup: sup, sub: argument)
    }

    private mutating func parseAtom() -> MathNode? {
        skipSpaces()
        guard index < chars.count else { return nil }
        let char = chars[index]
        switch char {
        case "{":
            index += 1
            guard let row = parseRow(insideGroup: true) else { return nil }
            guard index < chars.count, chars[index] == "}" else { return nil }
            index += 1
            return row
        case "}", "^", "_", "&", "#":
            return nil
        case "\\":
            return parseCommand()
        default:
            index += 1
            if char.isNumber {
                var text = String(char)
                while index < chars.count, chars[index].isNumber || decimalPoint(at: index) {
                    text.append(chars[index])
                    index += 1
                }
                return .atom(text, .ordinary)
            }
            return .atom(MathSymbols.character(char), MathSymbols.classOf(char))
        }
    }

    /// A dot between two digits belongs to the number, a dot after them ends a
    /// sentence.
    private func decimalPoint(at position: Int) -> Bool {
        chars[position] == "." && position + 1 < chars.count && chars[position + 1].isNumber
    }

    private mutating func parseCommand() -> MathNode? {
        index += 1
        guard index < chars.count else { return nil }
        let first = chars[index]
        guard first.isLetter else {
            index += 1
            switch first {
            case ",": return .space(0.17)
            case ":": return .space(0.22)
            case ";": return .space(0.28)
            case "!": return .space(-0.17)
            case " ": return .space(0.25)
            case "{", "}", "%", "$", "&", "#", "_": return .atom(String(first), .ordinary)
            // `\\` ends a line, and a formula with lines in it is a layout this
            // does not have.
            default: return nil
            }
        }
        var name = ""
        while index < chars.count, chars[index].isLetter {
            name.append(chars[index])
            index += 1
        }
        switch name {
        case "frac", "dfrac", "tfrac":
            guard let numerator = parseAtom(), let denominator = parseAtom() else { return nil }
            return .fraction(numerator, denominator)
        case "sqrt":
            skipSpaces()
            // `\sqrt[3]{x}` needs the index drawn into the radical's crook.
            guard index < chars.count, chars[index] != "[" else { return nil }
            guard let body = parseAtom() else { return nil }
            return .radical(body)
        case "text", "mathrm", "operatorname":
            guard let body = readBraced() else { return nil }
            return .atom(body, .text)
        case "left", "right", "bigl", "bigr", "big", "Big", "biggl", "biggr":
            skipSpaces()
            guard index < chars.count else { return nil }
            // `\left.` is a bracket the author asked not to draw.
            if chars[index] == "." {
                index += 1
                return .row([])
            }
            if chars[index] == "\\" {
                guard case .atom(let text, _)? = parseCommand() else { return nil }
                return .atom(text, .delimiter)
            }
            let delimiter = chars[index]
            index += 1
            return .atom(MathSymbols.character(delimiter), .delimiter)
        case "quad": return .space(1)
        case "qquad": return .space(2)
        default:
            guard let symbol = MathSymbols.table[name] else { return nil }
            return .atom(symbol.text, symbol.kind)
        }
    }

    /// The text inside `{…}`, braces balanced, or nil when there is no group.
    private mutating func readBraced() -> String? {
        skipSpaces()
        guard index < chars.count, chars[index] == "{" else { return nil }
        index += 1
        var depth = 1
        var text = ""
        while index < chars.count {
            let char = chars[index]
            index += 1
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return text }
            }
            text.append(char)
        }
        return nil
    }

    private mutating func skipSpaces() {
        while index < chars.count,
            chars[index] == " " || chars[index] == "\n"
                || chars[index] == "\t"
        {
            index += 1
        }
    }
}
