import Foundation

/// A resolved local-link target: the Markdown file to open and an optional
/// heading anchor to scroll to once it is rendered. [REF:fr:local-links]
struct LocalLink: Equatable {
    let fileURL: URL
    let anchor: String?
}

/// Pure grammar for hrefs clicked inside rendered documents. Default-deny:
/// only scheme-less, relative paths ending in `.md`/`.markdown` (with an
/// optional `#fragment`) resolve; everything else — external URLs,
/// protocol-relative links, absolute paths, non-Markdown files, malformed
/// percent-encoding — returns `nil` and the click stays dead.
/// [REF:fr:local-links]
enum LocalLinkResolver {
    /// Resolve `href` against the directory of `documentURL`. `..` traversal
    /// is allowed — repository documentation links across sibling folders.
    static func resolve(href: String, documentURL: URL) -> LocalLink? {
        guard !href.isEmpty, !href.hasPrefix("//"), !hasScheme(href) else { return nil }
        let split = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(split[0])
        guard !rawPath.isEmpty, !rawPath.hasPrefix("/") else { return nil }
        guard let path = rawPath.removingPercentEncoding else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else { return nil }
        let base = documentURL.deletingLastPathComponent()
        let fileURL = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        var anchor: String?
        if split.count > 1, !split[1].isEmpty {
            let rawAnchor = String(split[1])
            anchor = rawAnchor.removingPercentEncoding ?? rawAnchor
        }
        return LocalLink(fileURL: fileURL, anchor: anchor)
    }

    /// True when `href` starts with a URI scheme (`[A-Za-z][A-Za-z0-9+.-]*:`).
    /// A colon after the first `/`, `?`, or `#` is path data, not a scheme.
    private static func hasScheme(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":") else { return false }
        let head = href[href.startIndex..<colon]
        guard let first = head.first, first.isLetter else { return false }
        return head.allSatisfy { char in
            char.isLetter || char.isNumber || char == "+" || char == "." || char == "-"
        }
    }
}
