import MarkdownKit

/// The text a block contributes to Copy and Find, produced without typesetting.
///
/// Find has to look at every block in the document; laying each one out to read
/// its text would defeat the whole virtualized design. This produces exactly
/// the same characters `BlockLayoutEngine` puts in a box — a test holds the two
/// to each other — at the cost of an inline parse and nothing else.
public enum BlockPlainText {
    public static func text(document: Document, leaf: Int32) -> String {
        let block = document.block(leaf)
        let content = document.content(of: leaf)
        switch block.kind {
        case .codeBlock, .htmlBlock, .frontMatter:
            // A `<table>` is drawn as a table, so its text is the cells, not
            // the tags. Everything else raw stays raw.
            if block.kind == .htmlBlock, let table = HTMLTable.parse(content) {
                return gridText(document: document, table: table)
            }
            // Terminal escapes are colour, not text: the renderer takes them
            // out, so Find must not see them either.
            guard AnsiText.containsEscapes(content) else {
                return String(decoding: content, as: UTF8.self)
            }
            return String(decoding: AnsiText.strip(content), as: UTF8.self)
        case .thematicBreak:
            return ""
        case .disclosure:
            // A section's header says what the section is; its closing tag says
            // nothing. Neither shows the angle brackets it was written with.
            guard block.level == 1 else { return "" }
            let summary = Array(document.text(block.info).utf8)
            guard !summary.isEmpty else { return "Details" }
            let inline = InlineParser.parse(
                content: summary,
                references: document.references,
                documentBytes: document.bytes,
                footnotes: document.footnotes
            )
            return inlineText(content: summary, inline: inline, skipBytes: 0)
        case .table:
            return gridText(
                document: document,
                table: HTMLTable(gfm: document.table(at: leaf), document: document)
            )
        default:
            var skip = 0
            if let task = document.taskMarker(in: content, leaf: leaf) {
                skip = task.contentStart
            }
            let inline = InlineParser.parse(
                content: content,
                references: document.references,
                documentBytes: document.bytes,
                footnotes: document.footnotes
            )
            return inlineText(content: content, inline: inline, skipBytes: skip)
        }
    }

    /// The text of a grid, cell by cell in reading order — the same order and
    /// the same separators the layout puts in its own plain text.
    private static func gridText(document: Document, table: HTMLTable) -> String {
        var out = ""
        for (index, cell) in table.cells.enumerated() {
            let inline = InlineParser.parse(
                content: cell.content,
                references: document.references,
                documentBytes: document.bytes,
                footnotes: document.footnotes
            )
            out += inlineText(content: cell.content, inline: inline, skipBytes: 0)
            let endsRow = index == table.cells.count - 1 || table.cells[index + 1].row != cell.row
            out += endsRow ? "\n" : "\t"
        }
        return out
    }

    /// Mirrors `AttributedBuilder`'s append rules exactly — same substitutions
    /// for breaks, entities and image markers, in the same order.
    static func inlineText(content: [UInt8], inline: InlineContent, skipBytes: Int) -> String {
        var out = ""
        out.reserveCapacity(content.count)
        for run in inline.runs {
            switch run.kind {
            case .text:
                guard Int(run.range.end) > skipBytes else { continue }
                guard !InlineImage.isHiddenAltText(run: run, inline: inline) else { continue }
                var range = run.range
                if Int(range.start) < skipBytes { range.start = Int32(skipBytes) }
                out += content.text(in: range)
            case .entity:
                guard let scalar = Unicode.Scalar(run.scalar) else { continue }
                out.unicodeScalars.append(scalar)
            case .softBreak:
                out += " "
            case .hardBreak:
                out += "\n"
            case .image:
                out += imageText(run: run, inline: inline)
            }
        }
        return out
    }

    /// A picture that will be drawn occupies one placeholder character; one
    /// that cannot be drawn keeps the marker, and its alt text follows.
    private static func imageText(run: InlineRun, inline: InlineContent) -> String {
        guard run.link >= 0, Int(run.link) < inline.links.count,
            InlineImage.isDrawable(destination: inline.links[Int(run.link)].destination)
        else { return "🖼 " }
        return InlineImage.placeholder
    }
}
