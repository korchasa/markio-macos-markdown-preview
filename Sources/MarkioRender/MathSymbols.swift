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
