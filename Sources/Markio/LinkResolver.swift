import Foundation

/// Decides what a clicked link means.
///
/// Four outcomes: an anchor scrolls this document, a relative Markdown path
/// opens as another document, anything with a scheme goes to the system, and a
/// relative path to a file that is really there opens in an editor.
///
/// That fourth one used to be refused outright — default-deny, so a document
/// could never talk the viewer into opening an arbitrary file. The rule that
/// replaced it is narrower rather than looser, and it is written down here
/// because it is the whole safety argument: never an absolute path, never a
/// path that climbs out of the document's own folder, never a file that is not
/// there, and the file is handed to another app rather than read here.
enum LinkResolver {
    enum Target {
        case anchor(String)
        case document(URL, anchor: String?)
        case external(URL)
        /// A source file beside the document, and the line the text named.
        case file(URL, line: Int?)
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Whether this app will open a file — the same rule for a dropped file as
    /// for a link, so the two can never disagree about what is a document.
    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func resolve(destination: String, relativeTo base: URL?) -> Target? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            let slug =
                String(trimmed.dropFirst()).removingPercentEncoding
                ?? String(trimmed.dropFirst())
            return .anchor(slug)
        }

        // A scheme, or a protocol-relative URL, belongs to the browser.
        if trimmed.hasPrefix("//") { return externalTarget("https:" + trimmed) }
        if let schemeEnd = trimmed.firstIndex(of: ":"),
            trimmed[trimmed.startIndex..<schemeEnd].allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
            }), schemeEnd > trimmed.startIndex,
            !isLineNumber(trimmed[trimmed.index(after: schemeEnd)...])
        {
            return externalTarget(trimmed)
        }

        guard let base else { return nil }
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let anchor = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        guard !path.isEmpty else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        // Absolute paths are refused: a link in a document should only ever
        // reach files beside it.
        guard !decoded.hasPrefix("/") else { return nil }
        let (bare, line) = splitLine(decoded)
        let url = URL(fileURLWithPath: bare, relativeTo: base.deletingLastPathComponent())
            .standardizedFileURL
        if isMarkdown(url), line == nil { return .document(url, anchor: anchor) }
        // Everything else has to be a file that exists, inside the folder the
        // document itself sits in.
        let folder = base.deletingLastPathComponent().standardizedFileURL
        guard url.path.hasPrefix(folder.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return nil }
        return .file(url, line: line)
    }

    /// Digits and nothing else after the colon, which is a line number.
    ///
    /// A dot is a legal character in a URL scheme, so `main.swift:214` parses
    /// as one — and a bare file name with a line number, which is what an agent
    /// writes about a file in the folder it is describing, was refused as a
    /// scheme this app does not serve. A path with a folder in front of it
    /// never hit this, which is why it went unnoticed.
    private static func isLineNumber(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isNumber)
    }

    /// `Sources/a.swift:214` → the path and 214. A trailing colon with no
    /// digits after it is part of the name as far as this is concerned.
    private static func splitLine(_ path: String) -> (String, Int?) {
        guard let colon = path.lastIndex(of: ":"), colon != path.startIndex else {
            return (path, nil)
        }
        let tail = String(path[path.index(after: colon)...])
        guard let line = Int(tail), line > 0 else { return (path, nil) }
        return (String(path[path.startIndex..<colon]), line)
    }

    private static func externalTarget(_ string: String) -> Target? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        // `file:` is excluded on purpose: it would be a way around the
        // relative-path rule above.
        let allowed: Set<String> = ["http", "https", "mailto", "ftp", "ftps"]
        guard allowed.contains(scheme) else { return nil }
        return .external(url)
    }
}
