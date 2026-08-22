/// How a reader has arranged a table: sorted by a column, filtered to the rows
/// that match a word.
///
/// This is state on a window, like the zoom or the scroll position. The file is
/// never touched — sorting a table is a way of looking at it, not an edit — and
/// nothing here is written down anywhere that could be mistaken for one.
public struct TableArrangement: Sendable, Equatable {
    /// The column being sorted by, or nil for the order the author wrote.
    public var column: Int?
    public var ascending = true
    /// Rows are kept when any of their cells contains this, ignoring case.
    public var filter = ""

    public init(column: Int? = nil, ascending: Bool = true, filter: String = "") {
        self.column = column
        self.ascending = ascending
        self.filter = filter
    }

    public var isPlain: Bool { column == nil && filter.isEmpty }

    /// What clicking a header does: sort by it, then reverse, then go back to
    /// the author's order. Three states rather than two, because a reader who
    /// has sorted a table has no other way back to what the document said.
    public func clicking(column: Int) -> TableArrangement {
        var next = self
        if self.column != column {
            next.column = column
            next.ascending = true
        } else if ascending {
            next.ascending = false
        } else {
            next.column = nil
            next.ascending = true
        }
        return next
    }
}

extension HTMLTable {
    /// Whether this table can be rearranged at all.
    ///
    /// A merged cell makes a row something other than a row: moving one would
    /// move text that belongs to a neighbour as well. Such a table keeps its
    /// header inert rather than sorting wrongly.
    public var canRearrange: Bool {
        !cells.contains { $0.rowspan > 1 || $0.columnspan > 1 }
    }

    /// The header row's cells, left to right.
    public var headerCells: [Cell] {
        cells.filter { $0.isHeader && $0.row == headerRow }.sorted { $0.column < $1.column }
    }

    /// Which row is the header. Usually the first; a table with none has -1 and
    /// simply cannot be sorted by anything.
    public var headerRow: Int {
        cells.first(where: \.isHeader)?.row ?? -1
    }

    /// A copy of this table with its body rows sorted and filtered.
    ///
    /// The header stays where it is. Sorting is stable, so two clicks on one
    /// header cannot produce two different orders among equal values, and a
    /// column of numbers sorts as numbers rather than as the strings that
    /// happen to spell them.
    public func arranged(by arrangement: TableArrangement) -> HTMLTable {
        guard canRearrange, !arrangement.isPlain else { return self }
        let header = headerRow
        var bodyRows = Array(Set(cells.map(\.row)).subtracting([header])).sorted()

        if !arrangement.filter.isEmpty {
            let needle = arrangement.filter.lowercased()
            bodyRows = bodyRows.filter { row in
                cells.contains {
                    $0.row == row && Self.text(of: $0).lowercased().contains(needle)
                }
            }
        }
        if let column = arrangement.column {
            let keys = bodyRows.map { row -> (row: Int, key: SortKey) in
                let cell = cells.first { $0.row == row && $0.column == column }
                return (row, SortKey(cell.map(Self.text(of:)) ?? ""))
            }
            let sorted = keys.enumerated().sorted { left, right in
                if left.element.key == right.element.key { return left.offset < right.offset }
                return arrangement.ascending
                    ? left.element.key < right.element.key
                    : right.element.key < left.element.key
            }
            bodyRows = sorted.map(\.element.row)
        }

        var moved: [Cell] = []
        moved.reserveCapacity(cells.count)
        for cell in cells where cell.row == header {
            moved.append(cell)
        }
        for (position, row) in bodyRows.enumerated() {
            for var cell in cells where cell.row == row {
                cell.row = header + 1 + position
                moved.append(cell)
            }
        }
        moved.sort { $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row }
        return HTMLTable(
            cells: moved,
            rowCount: max(1, bodyRows.count + (header >= 0 ? 1 : 0)),
            columnCount: columnCount
        )
    }

    static func text(of cell: Cell) -> String {
        trimmed(InlineText.plain(cell.content))
    }

    /// MarkdownKit has no Foundation in it, so trimming is spelled out.
    static func trimmed(_ text: String) -> String {
        var characters = Substring(text)
        while let first = characters.first, first == " " || first == "\t" || first == "\n" {
            characters = characters.dropFirst()
        }
        while let last = characters.last, last == " " || last == "\t" || last == "\n" {
            characters = characters.dropLast()
        }
        return String(characters)
    }

    /// What a cell sorts as.
    ///
    /// A column of numbers must not sort as text, or 10 comes before 9; a
    /// column of dates written the ISO way already sorts correctly as text, so
    /// they are left to it. Everything else is compared case-insensitively,
    /// which is what a reader expects of a column of names.
    struct SortKey: Comparable, Equatable {
        var number: Double?
        var text: String

        init(_ raw: String) {
            let bare = HTMLTable.trimmed(raw)
            text = bare.lowercased()
            number = SortKey.number(in: bare)
        }

        /// A number with the units a table writes around it — `40 min`, `$12`,
        /// `1,024`, `18%` — is still a number for the purpose of sorting.
        private static func number(in raw: String) -> Double? {
            var digits = ""
            var seenDigit = false
            for character in raw {
                if character.isNumber || character == "." || character == "-" || character == "+" {
                    digits.append(character)
                    seenDigit = seenDigit || character.isNumber
                } else if character == "," {
                    continue
                } else if seenDigit {
                    break
                } else if character == "$" || character == "€" || character == "£"
                    || character == " "
                {
                    continue
                } else {
                    return nil
                }
            }
            guard seenDigit else { return nil }
            return Double(digits)
        }

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if let left = lhs.number, let right = rhs.number, left != right { return left < right }
            if lhs.number != nil, rhs.number == nil { return true }
            if lhs.number == nil, rhs.number != nil { return false }
            return lhs.text < rhs.text
        }
    }
}
