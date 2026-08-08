/// A parsed Markdown document: the source bytes, the flat block tree, the line
/// index, and the list of leaves that layout walks.
///
/// The document owns exactly one copy of the file. Every block, every heading
/// and every inline run refers back into it by byte range, so re-rendering at a
/// different width, searching, or jumping to a heading costs no new text.
public struct Document: Sendable {
    public let bytes: [UInt8]
    public let blocks: [Block]
    public let lines: LineIndex
    /// Indices of the blocks that carry content, in reading order. These are
    /// the units of layout: containers contribute indentation and decoration,
    /// never a box of their own.
    public let leaves: [Int32]
    /// Link reference definitions (`[label]: url "title"`), lowercased label →
    /// destination and title.
    public let references: [String: LinkReference]

    public struct LinkReference: Sendable, Equatable {
        public var destination: ByteRange
        public var title: ByteRange
    }

    public init(bytes: [UInt8]) {
        var parsed = bytes
        // A UTF-8 BOM would otherwise show up as a stray glyph in the first
        // block and shift every byte range by three.
        if parsed.count >= 3, parsed[0] == 0xEF, parsed[1] == 0xBB, parsed[2] == 0xBF {
            parsed.removeFirst(3)
        }
        let (blocks, lines, references) = parsed.withUnsafeBufferPointer {
            buffer -> ([Block], LineIndex, [String: LinkReference]) in
            var (blocks, lines) = BlockScanner.scan(bytes: buffer)
            let references = ReferenceCollector.collect(
                blocks: &blocks,
                lines: lines,
                bytes: buffer
            )
            return (blocks, lines, references)
        }
        self.bytes = parsed
        self.blocks = blocks
        self.lines = lines
        self.references = references
        var leaves: [Int32] = []
        leaves.reserveCapacity(blocks.count / 2 + 1)
        for index in blocks.indices where blocks[index].kind.isLeaf {
            // A paragraph that held nothing but link definitions is gone.
            if blocks[index].lineCount <= 0, blocks[index].kind != .thematicBreak { continue }
            leaves.append(Int32(index))
        }
        self.leaves = leaves
    }

    public init(text: String) {
        self.init(bytes: Array(text.utf8))
    }

    public var isEmpty: Bool { leaves.isEmpty }

    public func text(_ range: ByteRange) -> String { bytes.text(in: range) }

    public func block(_ index: Int32) -> Block { blocks[Int(index)] }

    /// The content of a leaf as one contiguous buffer, container scaffolding
    /// already stripped and lines rejoined with `\n`.
    ///
    /// This is the only place MarkdownKit copies document text, and it runs
    /// once per block that is actually about to be drawn.
    public func content(of index: Int32) -> [UInt8] {
        let block = blocks[Int(index)]
        if block.kind == .heading, !block.flags.contains(.setext) {
            return Array(bytes[block.info.lowerBound..<block.info.upperBound])
        }
        guard block.lineCount > 0 else { return [] }
        var out: [UInt8] = []
        return bytes.withUnsafeBufferPointer { buffer in
            var total = 0
            for line in Int(block.firstLine)...Int(block.lastLine) {
                total += lines.contentRange(of: line, bytes: buffer).count + 1
            }
            out.reserveCapacity(total)
            for line in Int(block.firstLine)...Int(block.lastLine) {
                let range = lines.contentRange(of: line, bytes: buffer)
                if !out.isEmpty { out.append(ASCII.newline) }
                out.append(contentsOf: buffer[range.lowerBound..<range.upperBound])
            }
            return out
        }
    }

    /// The byte span a leaf covers in the original file, used by search and by
    /// scroll restoration to talk about positions in source terms.
    public func sourceRange(of index: Int32) -> ByteRange {
        let block = blocks[Int(index)]
        guard block.lineCount > 0 else {
            let start = lines.start(of: Int(block.firstLine))
            return ByteRange(start, start)
        }
        let start = lines.start(of: Int(block.firstLine))
        let end = bytes.withUnsafeBufferPointer { lines.end(of: Int(block.lastLine), bytes: $0) }
        return ByteRange(start, end)
    }

    // MARK: - Container context

    /// How a leaf sits inside its containers: how deep in block quotes, how deep
    /// in lists, and whether it carries a list marker.
    public struct LeafContext: Sendable, Equatable {
        public var quoteDepth: Int = 0
        public var listDepth: Int = 0
        /// The enclosing list item, or -1.
        public var listItem: Int32 = -1
        /// The enclosing list, or -1.
        public var list: Int32 = -1
        /// This leaf is the one the item's bullet or number is drawn beside.
        public var isItemHead = false
        /// 1-based position of the item inside an ordered list.
        public var ordinal: Int32 = 0
        public var isTight = true
    }

    public func context(of index: Int32) -> LeafContext {
        var context = LeafContext()
        context.isItemHead = blocks[Int(index)].flags.contains(.itemHead)
        var parent = blocks[Int(index)].parent
        var innermostItem: Int32 = -1
        while parent >= 0 {
            let block = blocks[Int(parent)]
            switch block.kind {
            case .blockQuote:
                context.quoteDepth += 1
            case .listItem:
                if innermostItem < 0 { innermostItem = parent }
            case .list:
                context.listDepth += 1
                if context.list < 0 {
                    context.list = parent
                    context.isTight = block.flags.contains(.tight)
                }
            default:
                break
            }
            parent = block.parent
        }
        context.listItem = innermostItem
        if innermostItem >= 0, context.list >= 0 {
            context.ordinal = ordinal(ofItem: innermostItem, in: context.list)
        }
        return context
    }

    /// Position of an item in its list, counting from the list's declared start.
    private func ordinal(ofItem item: Int32, in list: Int32) -> Int32 {
        let start = blocks[Int(list)].flags.contains(.ordered) ? Int32(blocks[Int(list)].level) : 1
        var position: Int32 = 0
        var index = Int(list) + 1
        while index < blocks.count {
            let block = blocks[index]
            if block.parent == list, block.kind == .listItem {
                if Int32(index) == item { return start + position }
                position += 1
            }
            if Int32(index) == item { break }
            index += 1
        }
        return start + position
    }

    // MARK: - Headings

    public struct Heading: Sendable, Equatable {
        public var block: Int32
        public var level: Int
        public var text: String
        public var slug: String
    }

    /// The heading tree, with GitHub-style slugs deduplicated the way GitHub
    /// does it, so `#anchor` links from other tools land correctly.
    public func headings() -> [Heading] {
        var result: [Heading] = []
        var seen: [String: Int] = [:]
        for index in leaves {
            let block = blocks[Int(index)]
            guard block.kind == .heading else { continue }
            let text = InlineText.plain(content(of: index))
            var slug = Slug.make(text)
            if let count = seen[slug] {
                seen[slug] = count + 1
                slug = "\(slug)-\(count)"
            } else {
                seen[slug] = 1
            }
            result.append(Heading(block: index, level: Int(block.level), text: text, slug: slug))
        }
        return result
    }
}
