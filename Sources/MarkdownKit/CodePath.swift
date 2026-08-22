/// Recognising a path to a file inside ordinary text.
///
/// An agent's report is full of `Sources/MarkioRender/Mermaid.swift:214`, and
/// that is inert text in every Markdown viewer. Recognition lives here, beside
/// the autolink scanner, because it is a property of the text: the drawing, the
/// plain-text projection, find and copy all have to agree about which bytes
/// they are looking at, and they only can if one place decides.
///
/// What this does **not** do is say whether the file is there. That needs a
/// disk, and this module has none — so the answer here is "this looks like a
/// path", and the caller with the file system turns it into a link or leaves it
/// as text. Existence is the filter that makes the whole feature safe: a
/// document can name any path it likes and nothing happens unless the file is
/// really beside it.
public enum CodePath {
    /// A path found in text, with the line number written after it if there was
    /// one.
    public struct Candidate: Sendable, Equatable {
        /// Where the whole thing sits in the buffer that was scanned — path,
        /// colon and line number together, which is what becomes clickable.
        public var range: ByteRange
        public var path: String
        public var line: Int?

        public init(range: ByteRange, path: String, line: Int?) {
            self.range = range
            self.path = path
            self.line = line
        }
    }

    /// Extensions that make a bare file name a path even with no directory in
    /// it. Kept to what an engineering document names: a word with a dot in it
    /// is otherwise a sentence ending, a version number, or a host name.
    static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "py", "rb", "go", "rs", "c", "h", "cc", "cpp",
        "hpp", "m", "mm", "java", "kt", "kts", "cs", "php", "lua", "zig", "sh", "bash", "zsh",
        "yml", "yaml", "json", "toml", "ini", "sql", "md", "markdown", "txt", "css", "scss",
        "html", "xml", "plist", "entitlements", "gradle", "cmake", "mk", "proto", "graphql",
        "tf", "hcl", "vue", "svelte", "dart", "ex", "exs", "erl", "hs", "ml", "r", "jl", "pl",
    ]

    /// Every path-shaped run of bytes in a buffer.
    ///
    /// The buffer is a block's content — never a fenced code block, which the
    /// caller keeps out of this: `foo.md:12` inside a fence is a string in
    /// somebody's program, and turning it into a link would be reading their
    /// code as if it were prose about ours.
    public static func candidates(in bytes: [UInt8]) -> [Candidate] {
        var found: [Candidate] = []
        var index = 0
        while index < bytes.count {
            guard !isBoundary(bytes[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < bytes.count, !isBoundary(bytes[end]) { end += 1 }
            if let candidate = candidate(in: bytes, from: index, to: end) {
                found.append(candidate)
            }
            index = end
        }
        return found
    }

    /// What separates one word from the next.
    ///
    /// Brackets and quotes are boundaries so that `(Sources/a.swift:1)` and
    /// `"Sources/a.swift"` give up the path inside them; a comma or a full stop
    /// is trimmed from the tail below rather than here, because a file name may
    /// legitimately end in neither.
    private static func isBoundary(_ byte: UInt8) -> Bool {
        switch byte {
        case ASCII.space, ASCII.tab, ASCII.newline, ASCII.carriageReturn:
            return true
        case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x22, 0x27, 0x60, 0x3C, 0x3E, 0x2C:
            return true
        default:
            return false
        }
    }

    private static func candidate(in bytes: [UInt8], from start: Int, to end: Int) -> Candidate? {
        var last = end
        // Trailing sentence punctuation belongs to the prose, not to the name.
        while last > start, isTrailingPunctuation(bytes[last - 1]) { last -= 1 }
        guard last > start else { return nil }
        let text = bytes.text(in: ByteRange(start, last))
        guard let split = splitLine(text) else { return nil }
        guard isPathShaped(split.path) else { return nil }
        return Candidate(
            range: ByteRange(start, last), path: split.path,
            line: split.line)
    }

    private static func isTrailingPunctuation(_ byte: UInt8) -> Bool {
        // A colon is trimmed too: `see Sources/a.swift:` ends a sentence, and
        // the line number form is recovered below because it keeps its digits.
        byte == 0x2E || byte == 0x3B || byte == 0x21 || byte == 0x3F || byte == 0x3A
    }

    /// Split `path:214` or `path:214:7` into the path and the first number.
    ///
    /// A column is recognised and dropped: no editor this app can drive takes
    /// one, and keeping it in the path would make the file impossible to find.
    private static func splitLine(_ text: String) -> (path: String, line: Int?)? {
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return (text, nil) }
        // A scheme (`https://…`) is a URL and belongs to the autolink scanner.
        guard !text.contains("://") else { return nil }
        var path = String(parts[0])
        var line: Int?
        if parts.count >= 2, let number = Int(parts[1]), number > 0 {
            line = number
        } else {
            // Not a line number after all — a Windows drive, a time of day. The
            // whole thing stays the path and is judged as one.
            path = text
        }
        return (path, line)
    }

    private static func isPathShaped(_ path: String) -> Bool {
        guard !path.isEmpty, path.count < 512 else { return false }
        // Absolute paths never become links: a link in a document reaches the
        // files beside it and nothing else on the machine.
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        guard !path.contains("://"), !path.contains("\\") else { return false }
        // A leading `./` is how a path is often written and says nothing more.
        let bare = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        guard !bare.isEmpty, !bare.hasPrefix("/") else { return false }
        let name = bare.split(separator: "/").last.map(String.init) ?? bare
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        if bare.contains("/") { return true }
        // No directory in it, so the extension has to carry the whole claim.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        return sourceExtensions.contains(ext)
    }
}
