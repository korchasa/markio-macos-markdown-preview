import MarkdownKit

/// Renders a parsed document as an indented text tree.
///
/// Structural assertions read far better as one expected string than as a
/// dozen index lookups, and a diff on failure points straight at the block that
/// went wrong.
enum TreeDump {
    static func dump(_ document: Document) -> String {
        var lines: [String] = []
        for index in document.blocks.indices where index > 0 {
            let block = document.blocks[index]
            if block.kind.isLeaf, block.lineCount <= 0, block.kind != .thematicBreak { continue }
            let depth = depth(of: Int32(index), in: document)
            var line = String(repeating: "  ", count: depth) + label(block, document: document)
            if block.kind.isLeaf, let text = text(of: Int32(index), in: document) {
                line += " \"\(text)\""
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func depth(of index: Int32, in document: Document) -> Int {
        var depth = 0
        var parent = document.blocks[Int(index)].parent
        while parent > 0 {
            depth += 1
            parent = document.blocks[Int(parent)].parent
        }
        return depth
    }

    private static func label(_ block: Block, document: Document) -> String {
        switch block.kind {
        case .document: return "document"
        case .blockQuote: return "quote"
        case .list:
            var attributes = [block.flags.contains(.ordered) ? "ordered" : "bullet"]
            attributes.append(block.flags.contains(.tight) ? "tight" : "loose")
            return "list(\(attributes.joined(separator: ",")))"
        case .listItem: return "item"
        case .paragraph: return "para"
        case .heading:
            return "h\(block.level)\(block.flags.contains(.setext) ? "(setext)" : "")"
        case .codeBlock:
            let info = document.text(block.info)
            let fenced = block.flags.contains(.fenced) ? "fenced" : "indented"
            return info.isEmpty ? "code(\(fenced))" : "code(\(fenced),\(info))"
        case .htmlBlock: return "html"
        case .thematicBreak: return "hr"
        case .table: return "table(\(block.aux))"
        case .frontMatter: return "frontmatter"
        case .footnoteDefinition: return "footnote(\(document.text(block.info)))"
        }
    }

    /// Raw block content, with container scaffolding stripped by the scanner.
    /// Inline structure is a separate concern and has its own tests, so nothing
    /// here runs the inline parser.
    private static func text(of index: Int32, in document: Document) -> String? {
        guard document.block(index).kind != .thematicBreak else { return nil }
        let content = document.content(of: index)
        return String(decoding: content, as: UTF8.self).replacingOccurrences(
            of: "\n",
            with: "\\n"
        )
    }
}
