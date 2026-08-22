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

    /// One row of the strip: what dominates it, and what else landed in it.
    ///
    /// The second half is what keeps a single diagram inside a wall of prose
    /// from disappearing: on a document a thousand screens tall one row of the
    /// strip is many blocks, and the dominant class alone would hide every
    /// small thing in it.
    public struct Bin: Sendable, Equatable {
        public var dominant: Kind = .prose
        /// Bit per `Kind.rawValue`.
        public var present: UInt16 = 0
        /// True for a row no block reached — the document ends above it.
        public var isEmpty: Bool { present == 0 }

        public func has(_ kind: Kind) -> Bool { present & (1 << kind.rawValue) != 0 }
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

    /// Bin the classes into the rows of a strip.
    ///
    /// The axis is document height rather than byte offset, so a click on the
    /// map lands where the scrollbar beside it says it will: a stretch of dense
    /// code is few bytes and many points, and a map that disagreed with the
    /// thumb would be worse than no map. The cost is that heights above the
    /// viewport are estimates, so the strip settles as blocks are measured.
    ///
    /// A block of zero height — one inside a closed section — contributes
    /// nothing, which is the right answer without a rule for it: the map shows
    /// the document as it is on screen.
    public static func bins(
        classes: [Kind], rows: Int, total: CGFloat, height: (Int) -> CGFloat
    ) -> [Bin] {
        guard rows > 0 else { return [] }
        var bins = [Bin](repeating: Bin(), count: rows)
        guard total > 0, !classes.isEmpty else { return bins }
        var weights = [CGFloat](repeating: 0, count: rows)
        let scale = CGFloat(rows) / total

        var y: CGFloat = 0
        for ordinal in classes.indices {
            let blockHeight = height(ordinal)
            defer { y += blockHeight }
            guard blockHeight > 0 else { continue }
            let kind = classes[ordinal]
            let first = min(rows - 1, max(0, Int(y * scale)))
            let last = min(rows - 1, max(first, Int((y + blockHeight) * scale)))
            for row in first...last {
                let top = max(y, CGFloat(row) / scale)
                let bottom = min(y + blockHeight, CGFloat(row + 1) / scale)
                let overlap = max(0, bottom - top)
                bins[row].present |= 1 << kind.rawValue
                // A row is named by whatever fills most of it, with prose
                // counted at half: prose is what a document is made of between
                // the things a reader is hunting for, so when a row holds both,
                // the other one is the informative answer.
                let weight = kind == .prose ? overlap / 2 : overlap
                if weight > weights[row] {
                    weights[row] = weight
                    bins[row].dominant = kind
                }
            }
        }
        return bins
    }
}
