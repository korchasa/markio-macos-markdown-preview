import AppKit
import CoreText

/// A small, allocation-light syntax highlighter for fenced code blocks.
///
/// Deliberately not a parser: it recognises comments, strings, numbers and
/// keywords, which is what carries almost all of the readability benefit, and
/// it does so in one pass over the code's bytes. A real grammar per language
/// would be a large dependency to carry — exactly the kind of weight Markio 2
/// exists to avoid — and it would run on every code block that scrolls past.
struct SyntaxHighlighter {
    enum Token: UInt8 {
        case plain
        case keyword
        case type
        case string
        case number
        case comment
        case attribute
    }

    struct Span {
        var start: Int
        var end: Int
        var token: Token
    }

    struct Language {
        var keywords: Set<String>
        var types: Set<String>
        var lineComments: [String]
        var blockComment: (open: String, close: String)?
        var stringDelimiters: [UInt8]
        /// Languages where `#` starts a comment rather than a preprocessor line.
        var hashComment: Bool
    }

    /// Colours are resolved per theme once, not per token.
    struct Palette {
        var keyword: CGColor
        var type: CGColor
        var string: CGColor
        var number: CGColor
        var comment: CGColor
        var attribute: CGColor

        init(isDark: Bool) {
            func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
                CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
            }
            if isDark {
                keyword = color(255, 123, 172)
                type = color(120, 200, 255)
                string = color(255, 184, 108)
                number = color(190, 160, 255)
                comment = color(126, 134, 148)
                attribute = color(160, 220, 160)
            } else {
                keyword = color(170, 13, 145)
                type = color(11, 75, 150)
                string = color(196, 26, 22)
                number = color(28, 0, 207)
                comment = color(110, 118, 130)
                attribute = color(30, 110, 70)
            }
        }

        func color(for token: Token, fallback: CGColor) -> CGColor {
            switch token {
            case .plain: return fallback
            case .keyword: return keyword
            case .type: return type
            case .string: return string
            case .number: return number
            case .comment: return comment
            case .attribute: return attribute
            }
        }
    }

    /// Spans of the code that are not plain text, in order and non-overlapping.
    static func spans(code: [UInt8], language name: String) -> [Span] {
        guard let language = language(for: name), !code.isEmpty else { return [] }
        var spans: [Span] = []
        spans.reserveCapacity(code.count / 16 + 8)
        var index = 0
        let end = code.count

        while index < end {
            let byte = code[index]

            if let comment = matchLineComment(code, at: index, language: language) {
                var stop = comment
                while stop < end, code[stop] != asciiNewline { stop += 1 }
                spans.append(Span(start: index, end: stop, token: .comment))
                index = stop
                continue
            }
            if let block = language.blockComment, matches(code, at: index, block.open) {
                let closeBytes = Array(block.close.utf8)
                var stop = index + block.open.utf8.count
                while stop < end, !matches(code, at: stop, bytes: closeBytes) { stop += 1 }
                stop = min(end, stop + closeBytes.count)
                spans.append(Span(start: index, end: stop, token: .comment))
                index = stop
                continue
            }
            if language.stringDelimiters.contains(byte) {
                var stop = index + 1
                while stop < end, code[stop] != byte {
                    if code[stop] == asciiBackslash { stop += 1 }
                    if stop < end, code[stop] == asciiNewline, byte != asciiBacktick { break }
                    stop += 1
                }
                stop = min(end, stop + 1)
                spans.append(Span(start: index, end: stop, token: .string))
                index = stop
                continue
            }
            if byte >= asciiZero, byte <= asciiNine, index == 0 || !isWordByte(code[index - 1]) {
                var stop = index
                while stop < end, isNumberByte(code[stop]) { stop += 1 }
                spans.append(Span(start: index, end: stop, token: .number))
                index = stop
                continue
            }
            if isWordStart(byte) {
                var stop = index
                while stop < end, isWordByte(code[stop]) { stop += 1 }
                let word = String(decoding: code[index..<stop], as: UTF8.self)
                if language.keywords.contains(word) {
                    spans.append(Span(start: index, end: stop, token: .keyword))
                } else if language.types.contains(word) || startsUppercase(word) {
                    spans.append(Span(start: index, end: stop, token: .type))
                }
                index = stop
                continue
            }
            if byte == asciiAt {
                var stop = index + 1
                while stop < end, isWordByte(code[stop]) { stop += 1 }
                if stop > index + 1 {
                    spans.append(Span(start: index, end: stop, token: .attribute))
                }
                index = stop
                continue
            }
            index += 1
        }
        return spans
    }

    // MARK: - Language table

    private static func matchLineComment(
        _ code: [UInt8],
        at index: Int,
        language: Language
    ) -> Int? {
        if language.hashComment, code[index] == asciiHash { return index + 1 }
        for prefix in language.lineComments where matches(code, at: index, prefix) {
            return index + prefix.utf8.count
        }
        return nil
    }

    private static func matches(_ code: [UInt8], at index: Int, _ literal: String) -> Bool {
        matches(code, at: index, bytes: Array(literal.utf8))
    }

    private static func matches(_ code: [UInt8], at index: Int, bytes: [UInt8]) -> Bool {
        guard index + bytes.count <= code.count else { return false }
        for offset in bytes.indices where code[index + offset] != bytes[offset] { return false }
        return true
    }

    private static let cLike = [
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case",
        "default", "new", "delete", "class", "struct", "enum", "public", "private", "protected",
        "static", "const", "void", "int", "float", "double", "char", "bool", "true", "false",
        "null", "this", "try", "catch", "throw", "finally", "import", "export", "extends",
        "implements", "interface", "namespace", "typedef", "sizeof", "using", "template",
    ]

    private static let swiftWords = [
        "func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "repeat",
        "switch", "case", "default", "break", "continue", "struct", "class", "enum", "protocol",
        "extension", "init", "deinit", "self", "Self", "super", "import", "public", "private",
        "internal", "fileprivate", "open", "static", "final", "lazy", "weak", "unowned",
        "throws", "rethrows", "try", "catch", "throw", "defer", "where", "as", "is", "nil",
        "true", "false", "async", "await", "actor", "some", "any", "inout", "mutating",
        "typealias", "associatedtype", "subscript", "willSet", "didSet", "get", "set",
    ]

    private static let pythonWords = [
        "def", "class", "if", "elif", "else", "for", "while", "return", "yield", "import",
        "from", "as", "try", "except", "finally", "raise", "with", "lambda", "pass", "break",
        "continue", "global", "nonlocal", "assert", "del", "and", "or", "not", "in", "is",
        "None", "True", "False", "async", "await", "self",
    ]

    private static let goWords = [
        "func", "var", "const", "type", "struct", "interface", "map", "chan", "package",
        "import", "return", "if", "else", "for", "range", "switch", "case", "default", "go",
        "defer", "select", "break", "continue", "fallthrough", "nil", "true", "false", "make",
        "new", "len", "cap", "append", "error", "string", "int", "bool", "byte", "rune",
    ]

    private static let rustWords = [
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "use", "mod",
        "pub", "crate", "self", "super", "match", "if", "else", "loop", "while", "for", "in",
        "return", "break", "continue", "where", "as", "dyn", "ref", "move", "async", "await",
        "unsafe", "true", "false", "Some", "None", "Ok", "Err",
    ]

    private static let shellWords = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac",
        "function", "return", "export", "local", "readonly", "echo", "cd", "set", "unset",
        "source", "exit", "trap", "shift",
    ]

    private static let sqlWords = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
        "create", "table", "drop", "alter", "join", "left", "right", "inner", "outer", "on",
        "group", "by", "order", "having", "limit", "offset", "union", "distinct", "as", "and",
        "or", "not", "null", "primary", "key", "foreign", "references", "index", "view",
    ]

    private static func language(for name: String) -> Language? {
        switch name.lowercased() {
        case "swift":
            return Language(
                keywords: Set(swiftWords),
                types: ["String", "Int", "Double", "Bool", "Array", "Dictionary", "Set"],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: [asciiQuote],
                hashComment: false
            )
        case "python", "py":
            return Language(
                keywords: Set(pythonWords),
                types: ["str", "int", "float", "list", "dict", "set", "tuple", "bytes"],
                lineComments: [],
                blockComment: nil,
                stringDelimiters: [asciiQuote, asciiApostrophe],
                hashComment: true
            )
        case "go":
            return Language(
                keywords: Set(goWords),
                types: [],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: [asciiQuote, asciiBacktick],
                hashComment: false
            )
        case "rust", "rs":
            return Language(
                keywords: Set(rustWords),
                types: ["String", "Vec", "Option", "Result", "u8", "u32", "u64", "i32", "i64"],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: [asciiQuote],
                hashComment: false
            )
        case "sh", "bash", "zsh", "shell", "console", "terminal":
            return Language(
                keywords: Set(shellWords),
                types: [],
                lineComments: [],
                blockComment: nil,
                stringDelimiters: [asciiQuote, asciiApostrophe],
                hashComment: true
            )
        case "sql":
            return Language(
                keywords: Set(sqlWords + sqlWords.map { $0.uppercased() }),
                types: [],
                lineComments: ["--"],
                blockComment: ("/*", "*/"),
                stringDelimiters: [asciiApostrophe],
                hashComment: false
            )
        case "json":
            return Language(
                keywords: ["true", "false", "null"],
                types: [],
                lineComments: [],
                blockComment: nil,
                stringDelimiters: [asciiQuote],
                hashComment: false
            )
        case "yaml", "yml", "toml", "ini", "conf":
            return Language(
                keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                types: [],
                lineComments: [],
                blockComment: nil,
                stringDelimiters: [asciiQuote, asciiApostrophe],
                hashComment: true
            )
        case "js", "javascript", "ts", "typescript", "tsx", "jsx", "java", "kotlin", "c", "cpp",
            "c++", "cs", "csharp", "php", "scala", "dart", "groovy":
            return Language(
                keywords: Set(
                    cLike + [
                        "function", "let", "var", "async", "await", "yield", "of", "typeof",
                        "instanceof", "undefined", "readonly", "type", "abstract", "override",
                        "suspend", "val", "fun", "when", "object", "companion",
                    ]
                ),
                types: [],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: [asciiQuote, asciiApostrophe, asciiBacktick],
                hashComment: false
            )
        default:
            return nil
        }
    }

    // MARK: - Byte predicates

    private static func isWordStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        isWordStart(byte) || (byte >= asciiZero && byte <= asciiNine)
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        isWordByte(byte) || byte == 0x2E
    }

    private static func startsUppercase(_ word: String) -> Bool {
        guard let first = word.utf8.first else { return false }
        return first >= 0x41 && first <= 0x5A && word.utf8.count > 1
    }
}

private let asciiNewline: UInt8 = 0x0A
private let asciiQuote: UInt8 = 0x22
private let asciiHash: UInt8 = 0x23
private let asciiApostrophe: UInt8 = 0x27
private let asciiZero: UInt8 = 0x30
private let asciiNine: UInt8 = 0x39
private let asciiAt: UInt8 = 0x40
private let asciiBackslash: UInt8 = 0x5C
private let asciiBacktick: UInt8 = 0x60
