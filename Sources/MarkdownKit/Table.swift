/// GFM tables, resolved on demand from the lines the scanner grouped together.
///
/// The scanner only decides *that* a run of lines is a table and how many
/// columns it has. Splitting rows into cells is layout's problem and happens
/// when the table is about to be drawn, so a document full of tables costs
/// nothing until one scrolls into view.
public struct Table: Sendable {
    public enum Alignment: UInt8, Sendable {
        case none
        case left
        case center
        case right
    }

    public var alignments: [Alignment]
    /// Header cells, then one array per body row. Ranges point into the
    /// document buffer.
    public var header: [ByteRange]
    public var rows: [[ByteRange]]

    public var columnCount: Int { alignments.count }
}

extension Document {
    /// Split a table block into cells. The delimiter row is consumed for its
    /// alignments and never appears as content.
    public func table(at index: Int32) -> Table {
        let block = blocks[Int(index)]
        precondition(block.kind == .table, "table(at:) called on a \(block.kind) block")
        return bytes.withUnsafeBufferPointer { buffer in
            let first = Int(block.firstLine)
            let last = Int(block.lastLine)
            let columns = max(Int(block.aux), 1)
            let header = cells(inLine: first, buffer: buffer, columns: columns)
            var alignments = [Table.Alignment](repeating: .none, count: columns)
            if first + 1 <= last {
                let spec = cells(inLine: first + 1, buffer: buffer, columns: columns)
                for column in 0..<min(columns, spec.count) {
                    alignments[column] = alignment(of: spec[column], buffer: buffer)
                }
            }
            var rows: [[ByteRange]] = []
            if first + 2 <= last {
                rows.reserveCapacity(last - first - 1)
                for line in (first + 2)...last {
                    rows.append(cells(inLine: line, buffer: buffer, columns: columns))
                }
            }
            return Table(alignments: alignments, header: header, rows: rows)
        }
    }

    private func alignment(
        of range: ByteRange,
        buffer: UnsafeBufferPointer<UInt8>
    ) -> Table.Alignment {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, isSpaceOrTab(buffer[start]) { start += 1 }
        while end > start, isSpaceOrTab(buffer[end - 1]) { end -= 1 }
        guard start < end else { return .none }
        let left = buffer[start] == ASCII.colon
        let right = buffer[end - 1] == ASCII.colon
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    /// Split one row, honouring backslash escapes and code spans so a pipe
    /// inside `` `a|b` `` stays inside its cell. Short rows are padded and long
    /// rows truncated, exactly as GFM specifies.
    private func cells(
        inLine line: Int,
        buffer: UnsafeBufferPointer<UInt8>,
        columns: Int
    ) -> [ByteRange] {
        let range = lines.contentRange(of: line, bytes: buffer)
        var result: [ByteRange] = []
        result.reserveCapacity(columns)
        var index = range.lowerBound
        let end = range.upperBound
        if index < end, buffer[index] == ASCII.pipe { index += 1 }
        var cellStart = index
        var inCode = false
        while index < end {
            let byte = buffer[index]
            if byte == ASCII.backslash {
                index += 2
                continue
            }
            if byte == ASCII.backtick { inCode.toggle() }
            if byte == ASCII.pipe, !inCode {
                result.append(trimmed(ByteRange(cellStart, index), buffer: buffer))
                cellStart = index + 1
            }
            index += 1
        }
        // A trailing pipe closes the row; without one the tail is a final cell.
        let tail = trimmed(ByteRange(cellStart, end), buffer: buffer)
        if !(tail.isEmpty && result.count >= columns) { result.append(tail) }
        while result.count < columns { result.append(.empty) }
        if result.count > columns { result.removeSubrange(columns..<result.count) }
        return result
    }

    private func trimmed(_ range: ByteRange, buffer: UnsafeBufferPointer<UInt8>) -> ByteRange {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, isSpaceOrTab(buffer[start]) { start += 1 }
        while end > start, isSpaceOrTab(buffer[end - 1]) { end -= 1 }
        return ByteRange(start, end)
    }
}
