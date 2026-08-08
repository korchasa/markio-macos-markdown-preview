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
            return String(decoding: content, as: UTF8.self)
        case .thematicBreak:
            return ""
        case .table:
            return tableText(document: document, leaf: leaf)
        default:
            var skip = 0
            if let task = document.taskMarker(in: content, leaf: leaf) {
                skip = task.contentStart
            }
            let inline = InlineParser.parse(
                content: content,
                references: document.references,
                documentBytes: document.bytes
            )
            return inlineText(content: content, inline: inline, skipBytes: skip)
        }
    }

    private static func tableText(document: Document, leaf: Int32) -> String {
        let table = document.table(at: leaf)
        let columns = max(1, table.columnCount)
        var rows: [[ByteRange]] = [table.header]
        rows.append(contentsOf: table.rows)
        var out = ""
        for row in rows {
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : .empty
                let bytes = Array(document.bytes[cell.lowerBound..<cell.upperBound])
                let inline = InlineParser.parse(
                    content: bytes,
                    references: document.references,
                    documentBytes: document.bytes
                )
                out += inlineText(content: bytes, inline: inline, skipBytes: 0)
                out += column == columns - 1 ? "\n" : "\t"
            }
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
                out += "🖼 "
            }
        }
        return out
    }
}
