import AppKit
import CoreText

/// A formula, set with real glyphs instead of shown as its own source.
///
/// This is a small typesetter for the LaTeX people actually write in prose:
/// letters and numbers, Greek, the common operators and relations, scripts,
/// fractions, roots, accents, the alternative alphabets, and the handful of
/// environments a README uses — matrices, `cases`, `aligned`. It is deliberately
/// not a LaTeX engine: there are no macros, no counters, no page layout. Anything
/// it does not understand makes `parse` return nil, and the caller falls back to
/// showing the source, which is what the viewer did before this existed and is
/// never wrong, only unhelpful.
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
    /// always succeeds. `display` is what the author wrote: `$$…$$` puts the
    /// limits of a sum above and below its sign, `$…$` keeps them beside it so
    /// the line does not grow around one formula.
    static func box(source: String, base: CTFont, color: CGColor, display: Bool = false)
        -> MathBox?
    {
        guard let node = MathParser.parse(source) else { return nil }
        return MathLayout.box(node, size: CTFontGetSize(base), color: color, display: display)
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

/// A mark over or under a symbol. Anything a font already has is a glyph; a
/// bar is a rule, because a font's macron is the width of one letter and a bar
/// has to cover whatever it is put over.
enum MathAccent {
    case hat
    case tilde
    case dot
    case arrow
    case bar
    case underline
}

/// A face a run of a formula can be set in. Blackboard, script and fraktur are
/// not faces but characters — a font has one ℝ and no way to make another — so
/// they are handled by substituting the letters, not here.
enum MathVariant {
    case normal
    case bold
    case upright
    case italic
    case sansSerif
    case monospace
}

/// Rows and columns of formulas: a matrix, a `cases` brace, an aligned block.
struct MathGrid {
    enum Style {
        /// A matrix: every column centred.
        case centred
        /// `cases`: everything against the left.
        case left
        /// `aligned`: columns take turns, right then left, so the `=` of every
        /// line stands under the one above it.
        case alternating
    }

    var rows: [[MathNode]]
    var style: Style
    /// Brackets drawn around the whole block, grown to its height.
    var left: String?
    var right: String?
}

indirect enum MathNode {
    case row([MathNode])
    case atom(String, MathClass)
    case scripted(base: MathNode, sup: MathNode?, sub: MathNode?)
    case fraction(MathNode, MathNode)
    /// A root, with the degree written into its crook when there is one.
    case radical(MathNode, degree: MathNode?)
    /// A mark drawn over or under what it belongs to.
    case accented(MathNode, MathAccent)
    /// A run set in another face: bold, upright, sans, monospace.
    case styled(MathNode, MathVariant)
    case grid(MathGrid)
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
            var degree: MathNode?
            if index < chars.count, chars[index] == "[" {
                index += 1
                guard let inner = parseRow(until: "]") else { return nil }
                degree = inner
            }
            guard let body = parseAtom() else { return nil }
            return .radical(body, degree: degree)
        case "text", "mathrm", "operatorname":
            guard let body = readBraced() else { return nil }
            return .atom(body, .text)
        case "mathbb", "mathcal", "mathfrak", "mathscr":
            // These are not faces a font can be asked for; they are their own
            // characters, and a letter without one falls back to itself.
            guard let body = readBraced() else { return nil }
            return .atom(MathSymbols.lettering(body, style: name), .ordinary)
        case "mathbf", "boldsymbol":
            guard let body = readGroup() else { return nil }
            return .styled(body, .bold)
        case "mathit":
            guard let body = readGroup() else { return nil }
            return .styled(body, .italic)
        case "mathsf", "textsf":
            guard let body = readGroup() else { return nil }
            return .styled(body, .sansSerif)
        case "mathtt", "texttt":
            guard let body = readGroup() else { return nil }
            return .styled(body, .monospace)
        case "hat", "widehat":
            return accent(.hat)
        case "tilde", "widetilde":
            return accent(.tilde)
        case "dot":
            return accent(.dot)
        case "vec":
            return accent(.arrow)
        case "bar", "overline":
            return accent(.bar)
        case "underline":
            return accent(.underline)
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
        case "begin":
            guard let name = readBraced(), let grid = environment(named: name) else { return nil }
            return grid
        case "quad": return .space(1)
        case "qquad": return .space(2)
        default:
            guard let symbol = MathSymbols.table[name] else { return nil }
            return .atom(symbol.text, symbol.kind)
        }
    }

    /// The brackets and the alignment each environment is drawn with. A name
    /// that is not here is not read at all — an `array` needs a column
    /// specification this does not parse, and a `gather` needs page-wide
    /// centring the line it sits on cannot give it.
    private static let environments:
        [String: (left: String?, right: String?, style: MathGrid.Style)] = [
            "matrix": (nil, nil, .centred),
            "pmatrix": ("(", ")", .centred),
            "bmatrix": ("[", "]", .centred),
            "Bmatrix": ("{", "}", .centred),
            "vmatrix": ("|", "|", .centred),
            "Vmatrix": ("\u{2016}", "\u{2016}", .centred),
            "smallmatrix": (nil, nil, .centred),
            "cases": ("{", nil, .left),
            "aligned": (nil, nil, .alternating),
            "align": (nil, nil, .alternating),
            "alignedat": (nil, nil, .alternating),
            "split": (nil, nil, .alternating),
        ]

    /// Rows of cells up to `\end{name}`.
    private mutating func environment(named name: String) -> MathNode? {
        guard let shape = MathParser.environments[name] else { return nil }
        var rows: [[MathNode]] = [[]]
        var cell: [MathNode] = []
        while true {
            skipSpaces()
            guard index < chars.count else { return nil }
            if chars[index] == "&" {
                index += 1
                rows[rows.count - 1].append(.row(cell))
                cell = []
                continue
            }
            if chars[index] == "\\" {
                if peekCommand() == "end" {
                    // `\end{other}` closes something this never opened.
                    index += 1
                    _ = readCommandName()
                    guard readBraced() == name else { return nil }
                    rows[rows.count - 1].append(.row(cell))
                    return .grid(
                        MathGrid(
                            rows: rows.filter { !$0.isEmpty },
                            style: shape.style,
                            left: shape.left,
                            right: shape.right
                        )
                    )
                }
                if index + 1 < chars.count, chars[index + 1] == "\\" {
                    index += 2
                    rows[rows.count - 1].append(.row(cell))
                    cell = []
                    rows.append([])
                    continue
                }
            }
            // A cell is a formula in its own right, scripts and all.
            if chars[index] == "^" || chars[index] == "_" {
                let raised = chars[index] == "^"
                index += 1
                guard let argument = parseAtom() else { return nil }
                let base = cell.popLast() ?? .empty
                guard let scripted = attach(argument, to: base, raised: raised) else { return nil }
                cell.append(scripted)
                continue
            }
            guard let atom = parseAtom() else { return nil }
            cell.append(atom)
        }
    }

    /// The command name after the backslash at the cursor, without moving it.
    private func peekCommand() -> String {
        var cursor = index + 1
        var name = ""
        while cursor < chars.count, chars[cursor].isLetter {
            name.append(chars[cursor])
            cursor += 1
        }
        return name
    }

    private mutating func readCommandName() -> String {
        var name = ""
        while index < chars.count, chars[index].isLetter {
            name.append(chars[index])
            index += 1
        }
        return name
    }

    private mutating func accent(_ mark: MathAccent) -> MathNode? {
        guard let body = parseAtom() else { return nil }
        return .accented(body, mark)
    }

    /// A braced group parsed as a formula rather than read as plain text.
    private mutating func readGroup() -> MathNode? {
        skipSpaces()
        guard index < chars.count, chars[index] == "{" else { return nil }
        index += 1
        guard let row = parseRow(insideGroup: true) else { return nil }
        guard index < chars.count, chars[index] == "}" else { return nil }
        index += 1
        return row
    }

    /// A formula up to a closing character that is not a brace — the `]` of a
    /// root's degree.
    private mutating func parseRow(until terminator: Character) -> MathNode? {
        var items: [MathNode] = []
        while true {
            skipSpaces()
            guard index < chars.count else { return nil }
            if chars[index] == terminator {
                index += 1
                return .row(items)
            }
            guard let atom = parseAtom() else { return nil }
            items.append(atom)
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
