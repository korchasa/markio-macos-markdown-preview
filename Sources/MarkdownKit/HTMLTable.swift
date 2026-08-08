/// A table written with HTML tags, resolved from the raw block a scanner left
/// behind.
///
/// Markdown's own table syntax cannot merge cells, so a document that needs a
/// merged cell has no choice but to write `<table>`. Showing that author the
/// source of their own table is the one case where "there is no HTML engine
/// here" turns from a virtue into a failure — so the tags that describe a grid
/// are read, and nothing else is.
///
/// Parsed on demand, when the block is about to be drawn, like every other
/// per-block cost in this parser. A document full of HTML tables costs nothing
/// until one scrolls into view.
public struct HTMLTable: Sendable {
    public struct Cell: Sendable {
        /// The cell's inner text, tags and all — the inline parser handles the
        /// ones that carry a style and drops the rest, exactly as it does in
        /// prose.
        public var content: [UInt8]
        public var isHeader: Bool
        /// Where the cell sits once the spans are resolved.
        public var row: Int
        public var column: Int
        public var rowspan: Int
        public var columnspan: Int
        public var alignment: Table.Alignment
    }

    public var cells: [Cell]
    public var rowCount: Int
    public var columnCount: Int

    /// Read a `<table>` element, or return nil when the bytes are not one.
    ///
    /// Nil is the honest answer for anything this does not understand — a table
    /// split by a blank line, a nested table, a stray closing tag. The caller
    /// then shows the source, which is what happened before this existed and is
    /// never wrong, only unhelpful.
    public static func parse(_ bytes: [UInt8]) -> HTMLTable? {
        var reader = Reader(bytes: bytes)
        guard reader.openTable() else { return nil }

        var cells: [Cell] = []
        // Which grid squares are taken, so a cell spanning down pushes the
        // cells of later rows to the right of it — the same bookkeeping a
        // browser does, and the only way spans land anywhere sensible.
        var occupied: Set<Int> = []
        var row = -1
        var columnCount = 0
        var sawRow = false

        while let tag = reader.nextTag() {
            switch tag.name {
            case "tr" where !tag.isClosing:
                row += 1
                sawRow = true
            case "td", "th":
                guard !tag.isClosing else { continue }
                if !sawRow {
                    // A cell outside any row still has to live somewhere.
                    row = max(row, 0)
                    sawRow = true
                }
                guard let content = reader.readCell(named: tag.name) else { return nil }
                var column = 0
                while occupied.contains(key(row: row, column: column)) { column += 1 }
                let columnspan = max(1, tag.number("colspan"))
                let rowspan = max(1, tag.number("rowspan"))
                for down in 0..<rowspan {
                    for across in 0..<columnspan {
                        occupied.insert(key(row: row + down, column: column + across))
                    }
                }
                columnCount = max(columnCount, column + columnspan)
                cells.append(
                    Cell(
                        content: content,
                        isHeader: tag.name == "th",
                        row: row,
                        column: column,
                        rowspan: rowspan,
                        columnspan: columnspan,
                        alignment: tag.alignment()
                    )
                )
            case "table" where tag.isClosing:
                guard !cells.isEmpty else { return nil }
                let rows = cells.map { $0.row + $0.rowspan }.max() ?? 0
                return HTMLTable(cells: cells, rowCount: rows, columnCount: columnCount)
            case "table" where !tag.isClosing:
                // A nested table would need a nested layout; the source says
                // more than half a table would.
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private static func key(row: Int, column: Int) -> Int { row &* 1024 &+ column }

    /// The cells of one row, left to right.
    public func cells(inRow row: Int) -> [Cell] {
        cells.filter { $0.row == row }
    }

    // MARK: - Reading

    private struct Tag {
        var name: String
        var isClosing: Bool
        /// The raw attribute text, read only when something asks for a value.
        var attributes: [UInt8]

        func number(_ attribute: String) -> Int {
            guard let value = value(of: attribute) else { return 0 }
            var number = 0
            for byte in value {
                guard isDigit(byte) else { return 0 }
                number = number * 10 + Int(byte - ASCII.zero)
                if number > 1000 { return 1000 }
            }
            return max(1, number)
        }

        func alignment() -> Table.Alignment {
            // `text-align: right` is how a table written this decade says it;
            // the bare attribute is how one written two decades ago did.
            var name = value(of: "align")
            if name == nil, let style = value(of: "style") {
                name = Tag.textAlign(in: style)
            }
            switch String(decoding: name ?? [], as: UTF8.self) {
            case "left": return .left
            case "right": return .right
            case "center", "centre": return .center
            default: return .none
            }
        }

        /// The word after `text-align:` inside a style attribute.
        private static func textAlign(in style: [UInt8]) -> [UInt8]? {
            let needle = Array("text-align".utf8)
            var index = 0
            while index + needle.count <= style.count {
                var offset = 0
                while offset < needle.count, lowercased(style[index + offset]) == needle[offset] {
                    offset += 1
                }
                guard offset == needle.count else {
                    index += 1
                    continue
                }
                var cursor = index + needle.count
                while cursor < style.count, isSpaceOrTab(style[cursor]) { cursor += 1 }
                guard cursor < style.count, style[cursor] == ASCII.colon else { return nil }
                cursor += 1
                while cursor < style.count, isSpaceOrTab(style[cursor]) { cursor += 1 }
                var word: [UInt8] = []
                while cursor < style.count, isAlpha(style[cursor]) {
                    word.append(lowercased(style[cursor]))
                    cursor += 1
                }
                return word
            }
            return nil
        }

        /// One attribute's value, read straight off the bytes. No `String`
        /// searching: MarkdownKit has no Foundation, on purpose.
        private func value(of attribute: String) -> [UInt8]? {
            let wanted = Array(attribute.utf8)
            var index = 0
            while index < attributes.count {
                while index < attributes.count, !isAlpha(attributes[index]) { index += 1 }
                let keyStart = index
                while index < attributes.count,
                    isAlpha(attributes[index]) || attributes[index] == ASCII.hyphen
                {
                    index += 1
                }
                let key = attributes[keyStart..<index].map(lowercased)
                while index < attributes.count, isSpaceOrTab(attributes[index]) { index += 1 }
                guard index < attributes.count, attributes[index] == ASCII.equals else { continue }
                index += 1
                while index < attributes.count, isSpaceOrTab(attributes[index]) { index += 1 }
                var value: [UInt8] = []
                if index < attributes.count,
                    attributes[index] == ASCII.quote || attributes[index] == ASCII.apostrophe
                {
                    let quote = attributes[index]
                    index += 1
                    while index < attributes.count, attributes[index] != quote {
                        value.append(attributes[index])
                        index += 1
                    }
                    if index < attributes.count { index += 1 }
                } else {
                    while index < attributes.count, !isWhitespaceByte(attributes[index]),
                        attributes[index] != ASCII.greaterThan
                    {
                        value.append(attributes[index])
                        index += 1
                    }
                }
                if key == wanted { return value.map(lowercased) }
            }
            return nil
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        /// Skip to just past `<table …>`, or say there is none.
        mutating func openTable() -> Bool {
            while index < bytes.count, isWhitespaceByte(bytes[index]) { index += 1 }
            guard let tag = nextTag(), tag.name == "table", !tag.isClosing else { return false }
            return true
        }

        mutating func nextTag() -> Tag? {
            while index < bytes.count, bytes[index] != ASCII.lessThan { index += 1 }
            guard index < bytes.count else { return nil }
            index += 1
            var isClosing = false
            if index < bytes.count, bytes[index] == ASCII.slash {
                isClosing = true
                index += 1
            }
            var name = ""
            while index < bytes.count, isAlphanumeric(bytes[index]), name.utf8.count < 12 {
                name.append(Character(UnicodeScalar(lowercased(bytes[index]))))
                index += 1
            }
            let attributeStart = index
            while index < bytes.count, bytes[index] != ASCII.greaterThan { index += 1 }
            let attributes = Array(bytes[attributeStart..<min(index, bytes.count)])
            if index < bytes.count { index += 1 }
            return Tag(name: name, isClosing: isClosing, attributes: attributes)
        }

        /// Everything up to the cell's closing tag, or up to the next cell when
        /// the author left the closing tag out — which HTML allows and people
        /// do.
        mutating func readCell(named name: String) -> [UInt8]? {
            let start = index
            var cursor = index
            while cursor < bytes.count {
                guard bytes[cursor] == ASCII.lessThan else {
                    cursor += 1
                    continue
                }
                let probe = peekName(at: cursor)
                if probe.name == name || probe.name == "td" || probe.name == "th"
                    || probe.name == "tr" || probe.name == "table"
                {
                    index = probe.isClosing && probe.name == name ? probe.end : cursor
                    return trimmed(Array(bytes[start..<cursor]))
                }
                cursor += 1
            }
            return nil
        }

        private func peekName(at position: Int) -> (name: String, isClosing: Bool, end: Int) {
            var cursor = position + 1
            var isClosing = false
            if cursor < bytes.count, bytes[cursor] == ASCII.slash {
                isClosing = true
                cursor += 1
            }
            var name = ""
            while cursor < bytes.count, isAlphanumeric(bytes[cursor]), name.utf8.count < 12 {
                name.append(Character(UnicodeScalar(lowercased(bytes[cursor]))))
                cursor += 1
            }
            while cursor < bytes.count, bytes[cursor] != ASCII.greaterThan { cursor += 1 }
            return (name, isClosing, min(cursor + 1, bytes.count))
        }

        private func trimmed(_ slice: [UInt8]) -> [UInt8] {
            var start = 0
            var end = slice.count
            while start < end, isWhitespaceByte(slice[start]) { start += 1 }
            while end > start, isWhitespaceByte(slice[end - 1]) { end -= 1 }
            return Array(slice[start..<end])
        }
    }
}

extension HTMLTable {
    /// A Markdown table as a grid, so both kinds are drawn by one layout.
    ///
    /// Markdown cannot merge cells, so every cell here is one row and one
    /// column wide — the special case of the general grid, not a different
    /// thing.
    public init(gfm table: Table, document: Document) {
        var cells: [Cell] = []
        var rows: [[ByteRange]] = [table.header]
        rows.append(contentsOf: table.rows)
        let columns = max(1, table.columnCount)
        for (row, source) in rows.enumerated() {
            for column in 0..<columns {
                let range = column < source.count ? source[column] : .empty
                cells.append(
                    Cell(
                        content: Array(document.bytes[range.lowerBound..<range.upperBound]),
                        isHeader: row == 0,
                        row: row,
                        column: column,
                        rowspan: 1,
                        columnspan: 1,
                        alignment: table.alignments[min(column, table.alignments.count - 1)]
                    )
                )
            }
        }
        self.init(cells: cells, rowCount: rows.count, columnCount: columns)
    }
}
