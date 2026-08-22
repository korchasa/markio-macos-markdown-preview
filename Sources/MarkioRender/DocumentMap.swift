import CoreGraphics
import MarkdownKit

/// The shape of a whole document, drawn small.
///
/// The scrollbar answers one question — how far down am I — and answers it
/// badly on a document a thousand screens tall, where the thumb is a few points
/// high and the same for every file. The map answers the question a reader of a
/// long report actually has: what is this document made of, and which part of it
/// is the part I want. An agent's report is heading, prose, code, table,
/// diagram, repeated fifty times, and the map is that rhythm.
///
/// Everything here is arithmetic over the flat block array and the heights the
/// layout already keeps, with no AppKit in it, so all of it can be tested
/// without a window.
public enum DocumentMap {
    /// What a stretch of the document is made of.
    ///
    /// One byte per leaf — half a megabyte on a 32 MB document, against the
    /// 13 MB the block array itself costs there — kept so the pixel bins can be
    /// rebuilt whenever the heights change without walking the document again.
    public enum Kind: UInt8, Sendable, CaseIterable {
        case prose
        case heading
        case code
        case diagram
        case table
        case quote
        case list
        case picture
        case rule
    }

    /// One row of the map: a slice of a source line, as the runs of ink on it.
    ///
    /// The map draws what the document actually says — the shape of its words,
    /// their indentation, the length of its lines — rather than a colour per
    /// kind of block. A row is what one line of the file looks like from far
    /// away, and a line too long for the map is cut off at its edge rather than
    /// wrapped: one row per line keeps the map's arithmetic exact, so the
    /// rectangle showing where the reader is cannot drift away from the lines
    /// it is meant to be marking.
    public struct Row: Sendable, Equatable {
        /// What kind of block the line belongs to, which is what colours it.
        public var kind: Kind = .prose
        /// The leaf that owns the line, so a click on the row can go to it.
        public var ordinal: Int = -1
        public var line: Int = 0
        /// Words, as a column and a length in columns.
        public var runs: [Run] = []

        public var isBlank: Bool { runs.isEmpty }
    }

    public struct Run: Sendable, Equatable {
        public var column: Int
        public var length: Int
    }

    /// What one leaf is, from the block layer alone: no text, no typesetting.
    ///
    /// A picture is the one guess. A paragraph whose first bytes are `![` is
    /// drawn as a picture far more often than not, and asking the inline parser
    /// instead would mean parsing every paragraph of the document to draw a
    /// strip 14 points wide. The heuristic is wrong at the edges — a paragraph
    /// that opens with an image and continues in prose counts as a picture —
    /// and that is the trade, not an oversight.
    public static func classify(_ document: Document, leaf: Int32) -> Kind {
        let block = document.block(leaf)
        switch block.kind {
        case .heading:
            return .heading
        case .table:
            return .table
        case .thematicBreak:
            return .rule
        case .frontMatter:
            return .code
        case .codeBlock:
            // A Mermaid fence is a picture the author drew in text. The info
            // string is the whole test here, where the layout also asks whether
            // the diagram parses: reading every fence in the document to colour
            // a strip 14 points wide would cost more than the strip is worth,
            // and a fence that says `mermaid` and does not parse is a mistake
            // in the document rather than a class of its own.
            return document.text(block.info) == "mermaid" ? .diagram : .code
        case .htmlBlock:
            return HTMLTable.parse(document.content(of: leaf)) != nil ? .table : .code
        default:
            break
        }
        if opensWithImage(document, leaf: leaf) { return .picture }
        return enclosure(document, of: block)
    }

    /// Whether a leaf's first line opens with `![`.
    ///
    /// Read straight out of the document's bytes rather than through
    /// `content(of:)`, which copies the block: this runs once per leaf, and on
    /// a 32 MB document that copy would be the document again.
    private static func opensWithImage(_ document: Document, leaf: Int32) -> Bool {
        let block = document.block(leaf)
        guard block.lineCount > 0 else { return false }
        var index = document.lines.start(of: Int(block.firstLine))
        let bytes = document.bytes
        // Past the scaffolding a container leaves at the head of the line — the
        // indentation, a quote's `>`, a list item's marker — so a picture that
        // is the whole of a list item still counts as one.
        var markers = 0
        while index < bytes.count, markers < 8 {
            let byte = bytes[index]
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "*") || byte == UInt8(ascii: "+")
            {
                index += 1
                markers += 1
            } else {
                break
            }
        }
        guard index + 1 < bytes.count else { return false }
        return bytes[index] == UInt8(ascii: "!") && bytes[index + 1] == UInt8(ascii: "[")
    }

    /// Prose, or the container it sits in. Two or three hops up a flat array of
    /// indices, so it costs nothing per block.
    private static func enclosure(_ document: Document, of block: Block) -> Kind {
        var parent = block.parent
        while parent >= 0 {
            let container = document.block(parent)
            switch container.kind {
            case .blockQuote: return .quote
            case .list, .listItem: return .list
            default: parent = container.parent
            }
        }
        return .prose
    }

    /// The rows of the map, starting at a line of the source.
    ///
    /// Reading the bytes is the whole cost: no typesetting, no attributed
    /// strings, nothing that scales with the size of the document. Only the
    /// lines that fit on the strip are ever looked at, which is why a map of a
    /// 32 MB document costs the same as a map of a short note — it shows a
    /// window onto the document and slides it, exactly as an editor's minimap
    /// does when a file is longer than its map.
    ///
    /// Words rather than characters: at one point per column a letter is not a
    /// letter any more, and what a reader recognises from across a room is the
    /// rhythm of the words and the indentation, not the glyphs.
    public static func rows(
        document: Document, classes: [Kind], fromLine: Int, maxRows: Int, columns: Int
    ) -> [Row] {
        guard maxRows > 0, columns > 0, document.lines.count > 0 else { return [] }
        var rows: [Row] = []
        rows.reserveCapacity(maxRows)
        var leaf = leafIndex(document, covering: fromLine)
        var line = max(0, fromLine)

        while line < document.lines.count, rows.count < maxRows {
            while leaf < document.leaves.count, lastLine(document, ordinal: leaf) < line {
                leaf += 1
            }
            let owns =
                leaf < document.leaves.count
                && document.block(document.leaves[leaf]).firstLine <= Int32(line)
            var row = Row()
            row.line = line
            row.ordinal = owns ? leaf : -1
            row.kind = kind(document, classes: classes, line: line, leaf: leaf, owns: owns)
            row.runs = runs(document, line: line).compactMap { run in
                guard run.column < columns else { return nil }
                return Run(column: run.column, length: min(run.length, columns - run.column))
            }
            rows.append(row)
            line += 1
        }
        return rows
    }

    /// What colours a line.
    ///
    /// A block's lines are not quite the lines a reader sees: a fenced code
    /// block covers its contents and not its fences, so the two fence lines
    /// belong to no block at all. They are plainly part of the code, so an
    /// orphan line touching a block takes that block's colour — the one after
    /// it if it opens one, the one before it if it closes one.
    private static func kind(
        _ document: Document, classes: [Kind], line: Int, leaf: Int, owns: Bool
    ) -> Kind {
        if owns { return leaf < classes.count ? classes[leaf] : .prose }
        if leaf < document.leaves.count, leaf < classes.count,
            Int(document.block(document.leaves[leaf]).firstLine) - line <= 1
        {
            return classes[leaf]
        }
        if leaf > 0, leaf - 1 < classes.count { return classes[leaf - 1] }
        return .prose
    }

    /// How many rows a whole document would take, for the slider's arithmetic.
    ///
    /// Lines rather than wrapped rows: counting the wrapped ones would mean
    /// reading every byte of the document, which is the one thing this must not
    /// do. A document of long paragraphs therefore slides a little faster than
    /// its map suggests, which nobody can see.
    public static func rowCount(_ document: Document) -> Int { document.lines.count }

    /// The words on a line, in columns, with a tab counted as four.
    private static func runs(_ document: Document, line: Int) -> [Run] {
        let bytes = document.bytes
        let start = document.lines.start(of: line)
        var end = Int(document.lines.starts[line + 1])
        if end > start, bytes[end - 1] == UInt8(ascii: "\n") { end -= 1 }
        if end > start, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
        guard end > start else { return [] }

        var runs: [Run] = []
        var column = 0
        var runStart = -1
        for index in start..<end {
            let byte = bytes[index]
            let isSpace = byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            if isSpace {
                if runStart >= 0 {
                    runs.append(Run(column: runStart, length: column - runStart))
                    runStart = -1
                }
                column += byte == UInt8(ascii: "\t") ? 4 : 1
            } else {
                if runStart < 0 { runStart = column }
                // A byte that continues a UTF-8 character is not a column of
                // its own, or every accented word would look twice as wide.
                if byte & 0xC0 != 0x80 { column += 1 }
            }
        }
        if runStart >= 0 { runs.append(Run(column: runStart, length: column - runStart)) }
        return runs
    }

    /// The leaf that owns a line, or the first one after it.
    public static func leafIndex(_ document: Document, covering line: Int) -> Int {
        var low = 0
        var high = document.leaves.count - 1
        var found = document.leaves.count
        while low <= high {
            let middle = (low + high) / 2
            if lastLine(document, ordinal: middle) >= line {
                found = middle
                high = middle - 1
            } else {
                low = middle + 1
            }
        }
        return found
    }

    /// The first line of a leaf, which is where a click on its row goes.
    public static func firstLine(_ document: Document, ordinal: Int) -> Int {
        guard ordinal >= 0, ordinal < document.leaves.count else { return 0 }
        return Int(document.block(document.leaves[ordinal]).firstLine)
    }

    private static func lastLine(_ document: Document, ordinal: Int) -> Int {
        let block = document.block(document.leaves[ordinal])
        return Int(block.firstLine) + max(0, Int(block.lineCount) - 1)
    }
}
