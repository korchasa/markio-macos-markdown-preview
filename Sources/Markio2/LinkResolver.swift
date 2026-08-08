import Foundation

/// Decides what a clicked link means.
///
/// Three outcomes and nothing else: an anchor scrolls this document, a relative
/// Markdown path opens as another document, and anything with a scheme goes to
/// the system. A relative path that is not Markdown is deliberately inert —
/// default-deny, so a document can never talk the viewer into opening an
/// arbitrary file.
enum LinkResolver {
    enum Target {
        case anchor(String)
        case document(URL, anchor: String?)
        case external(URL)
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
            }), schemeEnd > trimmed.startIndex
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
        let url = URL(fileURLWithPath: decoded, relativeTo: base.deletingLastPathComponent())
            .standardizedFileURL
        guard isMarkdown(url) else { return nil }
        return .document(url, anchor: anchor)
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
