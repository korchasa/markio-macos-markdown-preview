/// What LaTeX names mean, in characters a font already has.
///
/// The list is the vocabulary of prose mathematics: Greek, the operators and
/// relations that turn up in a README, arrows, set notation, and the function
/// names that are set upright. It is not the whole of LaTeX, and a name that is
/// missing makes the formula fall back to its source — so adding to this table
/// is the cheapest way to widen what gets typeset.
enum MathSymbols {
    static let table: [String: (text: String, kind: MathClass)] = {
        var table: [String: (text: String, kind: MathClass)] = [:]
        for (name, text) in greek { table[name] = (text, .variable) }
        for (name, text) in binaries { table[name] = (text, .binary) }
        for (name, text) in relations { table[name] = (text, .relation) }
        for (name, text) in ordinaries { table[name] = (text, .ordinary) }
        for (name, text) in larges { table[name] = (text, .large) }
        for name in functions { table[name] = (name, .function) }
        return table
    }()

    /// Lowercase Greek is italic like any other variable; the capitals are
    /// upright in every book that sets mathematics, but one italic capital sigma
    /// is a smaller error than a table of exceptions.
    private static let greek: [(String, String)] = [
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"),
        ("epsilon", "ε"), ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"),
        ("theta", "θ"), ("vartheta", "ϑ"), ("iota", "ι"), ("kappa", "κ"),
        ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"),
        ("pi", "π"), ("varpi", "ϖ"), ("rho", "ρ"), ("varrho", "ϱ"),
        ("sigma", "σ"), ("varsigma", "ς"), ("tau", "τ"), ("upsilon", "υ"),
        ("phi", "φ"), ("varphi", "ϕ"), ("chi", "χ"), ("psi", "ψ"), ("omega", "ω"),
        ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"),
        ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"), ("Upsilon", "Υ"),
        ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
    ]

    private static let binaries: [(String, String)] = [
        ("times", "×"), ("div", "÷"), ("pm", "±"), ("mp", "∓"), ("cdot", "⋅"),
        ("ast", "∗"), ("star", "⋆"), ("circ", "∘"), ("bullet", "∙"),
        ("cup", "∪"), ("cap", "∩"), ("setminus", "∖"), ("oplus", "⊕"),
        ("otimes", "⊗"), ("wedge", "∧"), ("land", "∧"), ("vee", "∨"), ("lor", "∨"),
    ]

    private static let relations: [(String, String)] = [
        ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"), ("neq", "≠"), ("ne", "≠"),
        ("approx", "≈"), ("equiv", "≡"), ("sim", "∼"), ("simeq", "≃"), ("cong", "≅"),
        ("propto", "∝"), ("in", "∈"), ("notin", "∉"), ("ni", "∋"),
        ("subset", "⊂"), ("subseteq", "⊆"), ("supset", "⊃"), ("supseteq", "⊇"),
        ("to", "→"), ("rightarrow", "→"), ("leftarrow", "←"), ("leftrightarrow", "↔"),
        ("Rightarrow", "⇒"), ("Leftarrow", "⇐"), ("Leftrightarrow", "⇔"),
        ("mapsto", "↦"), ("gg", "≫"), ("ll", "≪"), ("perp", "⊥"), ("parallel", "∥"),
    ]

    private static let ordinaries: [(String, String)] = [
        ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("forall", "∀"),
        ("exists", "∃"), ("nexists", "∄"), ("neg", "¬"), ("lnot", "¬"),
        ("emptyset", "∅"), ("varnothing", "∅"), ("angle", "∠"), ("degree", "°"),
        ("ldots", "…"), ("dots", "…"), ("cdots", "⋯"), ("vdots", "⋮"), ("ddots", "⋱"),
        ("prime", "′"), ("hbar", "ℏ"), ("ell", "ℓ"), ("Re", "ℜ"), ("Im", "ℑ"),
        ("aleph", "ℵ"), ("checkmark", "✓"), ("square", "□"),
    ]

    private static let larges: [(String, String)] = [
        ("sum", "∑"), ("prod", "∏"), ("coprod", "∐"), ("int", "∫"), ("iint", "∬"),
        ("oint", "∮"), ("bigcup", "⋃"), ("bigcap", "⋂"), ("bigoplus", "⨁"),
    ]

    /// Set upright, because `sin` is a name and `sin` would read as s·i·n.
    private static let functions = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "log", "ln", "lg", "exp", "lim", "limsup",
        "liminf", "max", "min", "sup", "inf", "det", "dim", "ker", "deg",
        "gcd", "arg", "mod", "bmod",
    ]

    /// `\mathbb{R}` and its neighbours, letter by letter.
    ///
    /// These alphabets are characters, not faces: Unicode has one ℝ and a font
    /// cannot be asked to make another. Most of each alphabet sits in one block,
    /// with the letters that were encoded earlier — ℝ, ℕ, ℒ and the rest —
    /// scattered outside it. A letter with no such character is left as it is,
    /// which reads as plain but never as wrong.
    static func lettering(_ text: String, style: String) -> String {
        let table: [Character: UnicodeScalar]
        let upper: UInt32
        let lower: UInt32
        switch style {
        case "mathbb":
            table = doubleStruck
            (upper, lower) = (0x1D538, 0x1D552)
        case "mathfrak":
            table = fraktur
            (upper, lower) = (0x1D504, 0x1D51E)
        default:
            table = script
            (upper, lower) = (0x1D49C, 0x1D4B6)
        }
        var out = ""
        for char in text {
            if let special = table[char] {
                out.unicodeScalars.append(special)
                continue
            }
            guard let ascii = char.asciiValue else {
                out.append(char)
                continue
            }
            if char.isUppercase, let scalar = UnicodeScalar(upper + UInt32(ascii - 65)) {
                out.unicodeScalars.append(scalar)
            } else if char.isLowercase, let scalar = UnicodeScalar(lower + UInt32(ascii - 97)) {
                out.unicodeScalars.append(scalar)
            } else if style == "mathbb", char.isNumber,
                let scalar = UnicodeScalar(0x1D7D8 + UInt32(ascii - 48))
            {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(char)
            }
        }
        return out
    }

    private static let doubleStruck: [Character: UnicodeScalar] = [
        "C": "\u{2102}", "H": "\u{210D}", "N": "\u{2115}", "P": "\u{2119}",
        "Q": "\u{211A}", "R": "\u{211D}", "Z": "\u{2124}",
    ]

    private static let script: [Character: UnicodeScalar] = [
        "B": "\u{212C}", "E": "\u{2130}", "F": "\u{2131}", "H": "\u{210B}",
        "I": "\u{2110}", "L": "\u{2112}", "M": "\u{2133}", "R": "\u{211B}",
        "e": "\u{212F}", "g": "\u{210A}", "o": "\u{2134}",
    ]

    private static let fraktur: [Character: UnicodeScalar] = [
        "C": "\u{212D}", "H": "\u{210C}", "I": "\u{2111}", "R": "\u{211C}",
        "Z": "\u{2128}",
    ]

    /// The mark drawn over or under an accented symbol.
    static func accent(_ mark: MathAccent) -> String {
        switch mark {
        case .hat: return "\u{02C6}"
        case .tilde: return "\u{02DC}"
        case .dot: return "\u{02D9}"
        case .arrow: return "\u{2192}"
        case .bar, .underline: return ""
        }
    }

    /// The character to draw for a plain source character. Only the ones whose
    /// mathematical shape differs from the ASCII the author typed are changed.
    static func character(_ char: Character) -> String {
        switch char {
        case "-": return "−"
        case "*": return "∗"
        case "'": return "′"
        case "<": return "<"
        case ">": return ">"
        default: return String(char)
        }
    }

    static func classOf(_ char: Character) -> MathClass {
        switch char {
        case "+", "-", "*", "/": return .binary
        case "=", "<", ">": return .relation
        case ",", ";", ":": return .punctuation
        case "(", ")", "[", "]", "|": return .delimiter
        default: return char.isLetter ? .variable : .ordinary
        }
    }
}
