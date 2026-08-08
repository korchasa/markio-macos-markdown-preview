/// Which flavour of raw HTML block a line opened, and therefore what closes it.
///
/// Markio 2 renders raw HTML as source text rather than interpreting it — there
/// is no HTML engine in the app by design. The distinction still matters for
/// *structure*: a `<div>` block ends at a blank line, a `<!-- comment -->` ends
/// at its closer, and getting that wrong swallows the rest of the document.
public enum HTMLBlockKind: UInt8, Sendable {
    /// `<script>`, `<pre>`, `<style>`, `<textarea>` — ends at the closing tag.
    case rawText = 1
    /// `<!-- … -->`
    case comment = 2
    /// `<? … ?>`
    case processingInstruction = 3
    /// `<!DOCTYPE …>`
    case declaration = 4
    /// `<![CDATA[ … ]]>`
    case cdata = 5
    /// A known block-level tag — ends at a blank line.
    case blockTag = 6
}

/// Recognises HTML block openers and closers directly on the byte buffer.
enum HTMLBlockScanner {
    /// Tag names that open a block-level HTML block (CommonMark's type 6 list).
    /// Inline tags such as `<kbd>` are deliberately absent: they must stay
    /// inside their paragraph so the inline parser can render the text around
    /// them.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption",
        "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2",
        "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link",
        "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param",
        "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title",
        "tr", "track", "ul",
    ]

    private static let rawTextTags: Set<String> = ["script", "pre", "style", "textarea"]

    static func kind(bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> HTMLBlockKind? {
        guard start < end, bytes[start] == ASCII.lessThan else { return nil }
        var pos = start + 1
        guard pos < end else { return nil }

        if bytes[pos] == ASCII.bang {
            pos += 1
            guard pos < end else { return nil }
            if matches(bytes, at: pos, end: end, "--") { return .comment }
            if matches(bytes, at: pos, end: end, "[CDATA[") { return .cdata }
            if isAlpha(bytes[pos]) { return .declaration }
            return nil
        }
        if bytes[pos] == 0x3F { return .processingInstruction }
        if bytes[pos] == ASCII.slash { pos += 1 }
        guard pos < end, isAlpha(bytes[pos]) else { return nil }

        var name = ""
        name.reserveCapacity(12)
        while pos < end, isAlphanumeric(bytes[pos]), name.utf8.count < 12 {
            name.append(Character(UnicodeScalar(lowercased(bytes[pos]))))
            pos += 1
        }
        // The name must be followed by whitespace, `>`, `/>` or end of line —
        // otherwise this is `<https://…>` or some other inline construct.
        let terminated =
            pos >= end || isSpaceOrTab(bytes[pos]) || bytes[pos] == ASCII.greaterThan
            || bytes[pos] == ASCII.slash
        guard terminated else { return nil }
        if rawTextTags.contains(name) { return .rawText }
        if blockTags.contains(name) { return .blockTag }
        return nil
    }

    static func ends(
        kind: HTMLBlockKind,
        bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int
    ) -> Bool {
        switch kind {
        case .rawText:
            return containsCloser(bytes, start: start, end: end, tags: rawTextTags)
        case .comment:
            return contains(bytes, start: start, end: end, "-->")
        case .processingInstruction:
            return contains(bytes, start: start, end: end, "?>")
        case .declaration:
            return contains(bytes, start: start, end: end, ">")
        case .cdata:
            return contains(bytes, start: start, end: end, "]]>")
        case .blockTag:
            // Ends at a blank line, which the scanner detects before ever
            // asking this question.
            return false
        }
    }

    private static func containsCloser(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int,
        tags: Set<String>
    ) -> Bool {
        var index = start
        while index + 1 < end {
            if bytes[index] == ASCII.lessThan, bytes[index + 1] == ASCII.slash {
                var pos = index + 2
                var name = ""
                while pos < end, isAlpha(bytes[pos]), name.utf8.count < 12 {
                    name.append(Character(UnicodeScalar(lowercased(bytes[pos]))))
                    pos += 1
                }
                if tags.contains(name) { return true }
            }
            index += 1
        }
        return false
    }

    private static func matches(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        end: Int,
        _ literal: String
    ) -> Bool {
        let needle = Array(literal.utf8)
        guard start + needle.count <= end else { return false }
        for offset in needle.indices where bytes[start + offset] != needle[offset] {
            return false
        }
        return true
    }

    private static func contains(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int,
        _ literal: String
    ) -> Bool {
        let needle = Array(literal.utf8)
        guard needle.count <= end - start else { return false }
        var index = start
        while index + needle.count <= end {
            var offset = 0
            while offset < needle.count, bytes[index + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return true }
            index += 1
        }
        return false
    }
}
