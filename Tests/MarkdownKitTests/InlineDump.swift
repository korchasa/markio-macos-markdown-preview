import MarkdownKit

/// Renders inline runs in a compact notation so a test can assert the whole
/// result of parsing a line in one string.
///
/// `{b:…}` strong, `{i:…}` emphasis, `{s:…}` strikethrough, `{c:…}` code,
/// `{m:…}` math, `{k:…}` keyboard, `{h:…}` highlight, `{u:…}` underline,
/// `{l(dest):…}` link, `{img(dest):alt}` image, `↵` soft break, `⏎` hard break.
enum InlineDump {
    static func dump(_ markdown: String) -> String {
        let document = Document(text: markdown)
        guard let leaf = document.leaves.first else { return "" }
        return dump(document: document, leaf: leaf)
    }

    static func dump(document: Document, leaf: Int32) -> String {
        let content = document.content(of: leaf)
        let parsed = InlineParser.parse(
            content: content,
            references: document.references,
            documentBytes: document.bytes
        )
        var out = ""
        for run in parsed.runs {
            switch run.kind {
            case .softBreak:
                out += "↵"
                continue
            case .hardBreak:
                out += "⏎"
                continue
            case .image:
                out += "{img(\(parsed.links[Int(run.link)].destination))}"
                continue
            case .entity:
                if let scalar = Unicode.Scalar(run.scalar) {
                    out.unicodeScalars.append(scalar)
                }
                continue
            case .text:
                break
            }
            let text = content.text(in: run.range)
            var wrapped = text
            if run.style.contains(.code) { wrapped = "{c:\(wrapped)}" }
            if run.style.contains(.math) { wrapped = "{m:\(wrapped)}" }
            if run.style.contains(.keyboard) { wrapped = "{k:\(wrapped)}" }
            if run.style.contains(.highlight) { wrapped = "{h:\(wrapped)}" }
            if run.style.contains(.underline) { wrapped = "{u:\(wrapped)}" }
            if run.style.contains(.strikethrough) { wrapped = "{s:\(wrapped)}" }
            if run.style.contains(.emphasis) { wrapped = "{i:\(wrapped)}" }
            if run.style.contains(.strong) { wrapped = "{b:\(wrapped)}" }
            if run.style.contains(.link), run.link >= 0 {
                wrapped = "{l(\(parsed.links[Int(run.link)].destination)):\(wrapped)}"
            }
            out += wrapped
        }
        return out
    }
}
