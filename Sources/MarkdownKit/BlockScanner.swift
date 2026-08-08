/// The block-structure pass: turns a byte buffer into a flat tree of blocks.
///
/// One forward pass over the lines, CommonMark's two-phase shape (match the
/// open containers, then open new ones, then classify the leaf). Nothing here
/// allocates per line: containers live on a small stack of value types, and a
/// leaf block records *which* lines it owns rather than copying their text.
///
/// Inline structure — emphasis, links, code spans — is deliberately not touched
/// here. It is parsed on demand, per block, when a block is about to be drawn.
struct BlockScanner {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var lines: LineIndex
    private var blocks: [Block] = []
    private var stack: [OpenFrame] = []
    /// Index of the open leaf block, or -1 when the tip of the stack is a container.
    private var openLeaf: Int32 = -1
    /// A blank line was seen; whether it makes an enclosing list loose depends
    /// on whether that list has more content after it.
    private var blankPending = false
    private var lastConsumedLine: Int32 = -1

    /// Per-open-block state the flat `Block` record has no room for.
    private struct OpenFrame {
        var block: Int32
        var kind: BlockKind
        /// Absolute column a list item's continuation lines must reach.
        var contentIndent: Int32 = 0
        /// Fence character, run length and indent of an open fenced code block.
        var fenceChar: UInt8 = 0
        var fenceLength: Int32 = 0
        var fenceIndent: Int32 = 0
        /// Set on a list when a blank line inside it is followed by more content.
        var loose = false
    }

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
        self.lines = LineIndex(bytes: bytes)
        // A block per ~4 lines is the shape of real documents; over-reserving
        // costs a little memory once, re-growing costs a copy of the whole tree.
        blocks.reserveCapacity(lines.count / 4 + 8)
        blocks.append(Block(kind: .document, parent: -1, firstLine: 0))
        stack.append(OpenFrame(block: 0, kind: .document))
    }

    static func scan(bytes: UnsafeBufferPointer<UInt8>) -> (blocks: [Block], lines: LineIndex) {
        var scanner = BlockScanner(bytes: bytes)
        scanner.run()
        return (scanner.blocks, scanner.lines)
    }

    private mutating func run() {
        var line = 0
        let lineCount = lines.count
        if lineCount > 0, let end = scanFrontMatter() {
            line = end
        }
        while line < lineCount {
            consume(line: line)
            line += 1
        }
        closeAll()
    }

    // MARK: - Front matter

    /// A `---` fence on the very first line opens YAML front matter, closed by
    /// the next `---` or `...`. Outside line 0 the same text is a thematic break
    /// or a setext underline, so this is checked once and never again.
    private mutating func scanFrontMatter() -> Int? {
        let start = lines.start(of: 0)
        let end = lines.end(of: 0, bytes: bytes)
        guard end - start >= 3, isRun(from: start, to: end, of: ASCII.hyphen, minimum: 3) else {
            return nil
        }
        var line = 1
        while line < lines.count {
            let lineStart = lines.start(of: line)
            let lineEnd = lines.end(of: line, bytes: bytes)
            let closing =
                isRun(from: lineStart, to: lineEnd, of: ASCII.hyphen, minimum: 3)
                || isRun(from: lineStart, to: lineEnd, of: ASCII.dot, minimum: 3)
            if closing {
                var block = Block(kind: .frontMatter, parent: 0, firstLine: 1)
                block.lineCount = Int32(line - 1)
                blocks.append(block)
                lastConsumedLine = Int32(line)
                return line + 1
            }
            line += 1
        }
        return nil
    }

    // MARK: - One line

    private mutating func consume(line: Int) {
        let lineStart = lines.start(of: line)
        let lineEnd = lines.end(of: line, bytes: bytes)
        var pos = lineStart
        var col = 0

        // Phase 1 — how much of the open container chain does this line still
        // belong to?
        var matched = 1
        while matched < stack.count {
            let frame = stack[matched]
            switch frame.kind {
            case .blockQuote:
                var probePos = pos
                var probeCol = col
                advanceIndent(&probePos, &probeCol, limit: col + 3, end: lineEnd)
                guard probePos < lineEnd, bytes[probePos] == ASCII.greaterThan else {
                    matched = -matched
                    break
                }
                probePos += 1
                probeCol += 1
                if probePos < lineEnd, bytes[probePos] == ASCII.space {
                    probePos += 1
                    probeCol += 1
                } else if probePos < lineEnd, bytes[probePos] == ASCII.tab {
                    probePos += 1
                    probeCol = nextTabStop(probeCol)
                }
                pos = probePos
                col = probeCol
            case .listItem:
                if isBlank(from: pos, to: lineEnd) {
                    // A blank line never breaks a list item; whether it makes
                    // the list loose is settled when content resumes.
                    pos = lineEnd
                    col = Int(frame.contentIndent)
                } else {
                    var probePos = pos
                    var probeCol = col
                    advanceIndent(
                        &probePos, &probeCol, limit: Int(frame.contentIndent), end: lineEnd)
                    guard probeCol >= Int(frame.contentIndent) else {
                        matched = -matched
                        break
                    }
                    pos = probePos
                    col = probeCol
                }
            default:
                break
            }
            if matched < 0 { break }
            matched += 1
        }
        let allMatched: Bool
        if matched < 0 {
            matched = -matched
            allMatched = false
        } else {
            allMatched = true
        }

        // Phase 2 — a fenced block swallows everything until its closer, so no
        // marker inside it is ever interpreted.
        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .codeBlock,
            blocks[Int(openLeaf)].flags.contains(.fenced), allMatched
        {
            let frame = stack[stack.count - 1]
            var probePos = pos
            var probeCol = col
            advanceIndent(&probePos, &probeCol, limit: col + 3, end: lineEnd)
            if probePos < lineEnd, bytes[probePos] == frame.fenceChar,
                runLength(from: probePos, to: lineEnd, of: frame.fenceChar)
                    >= Int(frame.fenceLength),
                isBlank(
                    from: probePos + runLength(from: probePos, to: lineEnd, of: frame.fenceChar),
                    to: lineEnd)
            {
                closeTip()
                lastConsumedLine = Int32(line)
                return
            }
            // Strip only as much indentation as the opening fence carried.
            var stripPos = pos
            var stripCol = col
            advanceIndent(&stripPos, &stripCol, limit: col + Int(frame.fenceIndent), end: lineEnd)
            appendLine(line, contentStart: stripPos)
            return
        }

        // Phase 3 — an unmatched container is fatal to the line unless the open
        // paragraph can swallow it as a lazy continuation.
        let blank = isBlank(from: pos, to: lineEnd)
        if !allMatched {
            if !blank, openLeaf >= 0, blocks[Int(openLeaf)].kind == .paragraph,
                !startsNewBlock(from: pos, to: lineEnd)
            {
                var textPos = pos
                var textCol = col
                advanceIndent(&textPos, &textCol, limit: Int.max, end: lineEnd)
                appendLine(line, contentStart: textPos)
                return
            }
            close(to: matched)
        }

        // Phase 4 — open whatever containers this line starts.
        if !blank {
            openContainers(pos: &pos, col: &col, lineEnd: lineEnd, line: line)
        }

        // Phase 5 — classify what is left of the line.
        classifyLeaf(line: line, pos: pos, col: col, lineEnd: lineEnd)
    }

    // MARK: - Containers

    private mutating func openContainers(pos: inout Int, col: inout Int, lineEnd: Int, line: Int) {
        while true {
            var probePos = pos
            var probeCol = col
            advanceIndent(&probePos, &probeCol, limit: col + 3, end: lineEnd)
            guard probePos < lineEnd else { return }

            if bytes[probePos] == ASCII.greaterThan {
                closeLeaf()
                // A quote at a list's own level ends the list rather than
                // joining it; a quote INSIDE an item continues that item, and a
                // blank line before it is what makes the list loose.
                while stack[stack.count - 1].kind == .list { closeTip() }
                noteContentAfterBlank()
                pos = probePos + 1
                col = probeCol + 1
                if pos < lineEnd, bytes[pos] == ASCII.space {
                    pos += 1
                    col += 1
                } else if pos < lineEnd, bytes[pos] == ASCII.tab {
                    pos += 1
                    col = nextTabStop(col)
                }
                push(kind: .blockQuote, firstLine: line)
                continue
            }

            // `---` is a thematic break or a setext underline, never a bullet.
            if isThematicBreak(from: probePos, to: lineEnd) { return }

            guard let marker = parseListMarker(at: probePos, col: probeCol, lineEnd: lineEnd) else {
                return
            }
            // A marker directly after paragraph text would split it mid-sentence;
            // only an empty item is disallowed there, matching CommonMark.
            if openLeaf >= 0, blocks[Int(openLeaf)].kind == .paragraph,
                marker.contentStart >= lineEnd
            {
                return
            }
            closeLeaf()
            openListIfNeeded(marker: marker, line: line)
            var item = Block(
                kind: .listItem, parent: stack[stack.count - 1].block, firstLine: Int32(line))
            item.aux = marker.start
            blocks.append(item)
            let index = Int32(blocks.count - 1)
            stack.append(
                OpenFrame(block: index, kind: .listItem, contentIndent: Int32(marker.contentIndent))
            )
            pos = marker.contentStart
            col = marker.contentIndent
        }
    }

    /// Reuse the enclosing list when this marker continues it; start a new one
    /// when the bullet character or the ordered/bullet nature changes.
    private mutating func openListIfNeeded(marker: ListMarker, line: Int) {
        let tip = stack[stack.count - 1]
        if tip.kind == .list {
            let list = blocks[Int(tip.block)]
            let sameOrder = list.flags.contains(.ordered) == marker.ordered
            if sameOrder, list.aux == Int32(marker.bullet) {
                // This item continues the open list, so a blank line before it
                // was a blank line *inside* the list.
                noteContentAfterBlank()
                return
            }
            closeTip()
        }
        // A brand-new list starts tight whatever preceded it: the blank line
        // belonged to what came before, not to this list.
        blankPending = false
        var flags: BlockFlags = [.tight]
        if marker.ordered { flags.insert(.ordered) }
        var list = Block(
            kind: .list,
            parent: stack[stack.count - 1].block,
            firstLine: Int32(line),
            flags: flags
        )
        list.aux = Int32(marker.bullet)
        blocks.append(list)
        let index = Int32(blocks.count - 1)
        stack.append(OpenFrame(block: index, kind: .list))
        // The first item's start number is what an ordered list counts from.
        if marker.ordered { blocks[Int(index)].level = UInt8(min(marker.start, 255)) }
    }

    private struct ListMarker {
        var bullet: UInt8
        var ordered: Bool
        var start: Int32
        var contentStart: Int
        var contentIndent: Int
    }

    private func parseListMarker(at start: Int, col: Int, lineEnd: Int) -> ListMarker? {
        var pos = start
        var ordered = false
        var number: Int32 = 0
        var bullet: UInt8 = 0

        let first = bytes[pos]
        if first == ASCII.hyphen || first == ASCII.plus || first == ASCII.asterisk {
            bullet = first
            pos += 1
        } else if isDigit(first) {
            var digits = 0
            while pos < lineEnd, isDigit(bytes[pos]), digits < 9 {
                number = number * 10 + Int32(bytes[pos] - ASCII.zero)
                pos += 1
                digits += 1
            }
            guard pos < lineEnd, bytes[pos] == ASCII.dot || bytes[pos] == ASCII.rightParen else {
                return nil
            }
            bullet = bytes[pos]
            ordered = true
            pos += 1
        } else {
            return nil
        }

        let markerEnd = pos
        var markerCol = col + (markerEnd - start)
        guard markerEnd >= lineEnd || isSpaceOrTab(bytes[markerEnd]) else { return nil }

        var contentPos = markerEnd
        var contentCol = markerCol
        advanceIndent(&contentPos, &contentCol, limit: markerCol + 4, end: lineEnd)
        let spaces = contentCol - markerCol
        // No content on the line, or an indented-code-sized gap: the item's
        // content column sits one space past the marker.
        if contentPos >= lineEnd || spaces == 0 || spaces > 4 {
            contentPos = markerEnd
            contentCol = markerCol + 1
            if contentPos < lineEnd, isSpaceOrTab(bytes[contentPos]) {
                contentPos += 1
            }
        }
        markerCol = contentCol
        return ListMarker(
            bullet: bullet,
            ordered: ordered,
            start: number,
            contentStart: contentPos,
            contentIndent: contentCol
        )
    }

    // MARK: - Leaves

    private mutating func classifyLeaf(line: Int, pos: Int, col: Int, lineEnd: Int) {
        if isBlank(from: pos, to: lineEnd) {
            closeLeafOnBlank()
            blankPending = true
            lastConsumedLine = Int32(line)
            return
        }
        // A list stays open only through its items. Content arriving at the
        // list's own level ends it — otherwise a quote or paragraph that
        // follows the list would be adopted as a child of it. Closing comes
        // first, so a blank line that merely separates a list from what follows
        // does not make that list loose.
        while stack[stack.count - 1].kind == .list { closeTip() }
        noteContentAfterBlank()

        // Measure the whole indent, not just the first three columns: four is
        // the threshold that turns a line into code, so a capped measurement
        // can never see it.
        var textPos = pos
        var textCol = col
        advanceIndent(&textPos, &textCol, limit: Int.max, end: lineEnd)
        let indent = textCol - col

        // Four columns of indentation is code — unless a paragraph is open, in
        // which case the line is simply more of that paragraph and no marker on
        // it means anything.
        if indent >= 4 {
            if openLeaf >= 0, blocks[Int(openLeaf)].kind == .paragraph {
                appendLine(line, contentStart: textPos)
                return
            }
            openIndentedCode(line: line, pos: pos, col: col, lineEnd: lineEnd)
            return
        }

        // An open code block that is not fenced ends as soon as a line is not
        // indented far enough; phase 2 handled the fenced case already.
        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .codeBlock,
            !blocks[Int(openLeaf)].flags.contains(.fenced)
        {
            closeLeaf()
        }

        if let level = atxHeadingLevel(at: textPos, lineEnd: lineEnd) {
            closeLeaf()
            let text = atxHeadingText(at: textPos, level: level, lineEnd: lineEnd)
            var heading = Block(
                kind: .heading,
                parent: stack[stack.count - 1].block,
                firstLine: Int32(line),
                level: UInt8(level),
                info: text
            )
            heading.lineCount = 1
            appendLeaf(heading, line: line, contentStart: textPos)
            closeLeaf()
            return
        }

        if let fence = fenceAt(textPos, lineEnd: lineEnd) {
            closeLeaf()
            let info = fenceInfo(after: textPos + fence.length, lineEnd: lineEnd)
            let code = Block(
                kind: .codeBlock,
                parent: stack[stack.count - 1].block,
                firstLine: Int32(line + 1),
                flags: [.fenced],
                info: info
            )
            blocks.append(code)
            openLeaf = Int32(blocks.count - 1)
            stack.append(
                OpenFrame(
                    block: openLeaf,
                    kind: .codeBlock,
                    fenceChar: fence.character,
                    fenceLength: Int32(fence.length),
                    fenceIndent: Int32(indent)
                )
            )
            markItemHead(openLeaf)
            lastConsumedLine = Int32(line)
            return
        }

        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .paragraph,
            let level = setextLevel(at: textPos, lineEnd: lineEnd)
        {
            blocks[Int(openLeaf)].kind = .heading
            blocks[Int(openLeaf)].level = UInt8(level)
            blocks[Int(openLeaf)].flags.insert(.setext)
            closeLeaf()
            lastConsumedLine = Int32(line)
            return
        }

        if isThematicBreak(from: textPos, to: lineEnd) {
            closeLeaf()
            var rule = Block(
                kind: .thematicBreak,
                parent: stack[stack.count - 1].block,
                firstLine: Int32(line)
            )
            rule.lineCount = 1
            appendLeaf(rule, line: line, contentStart: textPos)
            closeLeaf()
            return
        }

        if openLeaf < 0, bytes[textPos] == ASCII.lessThan,
            let kind = htmlBlockKind(at: textPos, lineEnd: lineEnd)
        {
            let html = Block(
                kind: .htmlBlock,
                parent: stack[stack.count - 1].block,
                firstLine: Int32(line),
                aux: Int32(kind.rawValue)
            )
            appendLeaf(html, line: line, contentStart: textPos)
            openLeaf = Int32(blocks.count - 1)
            if htmlBlockEnds(kind: kind, from: textPos, to: lineEnd) { closeLeaf() }
            return
        }

        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .htmlBlock {
            let block = blocks[Int(openLeaf)]
            appendLine(line, contentStart: pos)
            if let kind = HTMLBlockKind(rawValue: UInt8(block.aux)),
                htmlBlockEnds(kind: kind, from: textPos, to: lineEnd)
            {
                closeLeaf()
            }
            return
        }

        // A paragraph's first line plus a delimiter row is a GFM table.
        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .paragraph,
            blocks[Int(openLeaf)].lineCount == 1,
            let columns = tableDelimiterColumns(from: textPos, to: lineEnd),
            columns == tableCellCount(inLine: Int(blocks[Int(openLeaf)].firstLine))
        {
            blocks[Int(openLeaf)].kind = .table
            blocks[Int(openLeaf)].aux = Int32(columns)
            appendLine(line, contentStart: textPos)
            return
        }
        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .table {
            if tableCellCount(inLine: line, from: textPos, to: lineEnd) == 0 {
                closeLeaf()
            } else {
                appendLine(line, contentStart: textPos)
                return
            }
        }

        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .paragraph {
            appendLine(line, contentStart: textPos)
            return
        }

        closeLeaf()
        let paragraph = Block(
            kind: .paragraph,
            parent: stack[stack.count - 1].block,
            firstLine: Int32(line)
        )
        appendLeaf(paragraph, line: line, contentStart: textPos)
        openLeaf = Int32(blocks.count - 1)
    }

    private mutating func openIndentedCode(line: Int, pos: Int, col: Int, lineEnd: Int) {
        var stripPos = pos
        var stripCol = col
        advanceIndent(&stripPos, &stripCol, limit: col + 4, end: lineEnd)
        if openLeaf >= 0, blocks[Int(openLeaf)].kind == .codeBlock,
            !blocks[Int(openLeaf)].flags.contains(.fenced)
        {
            appendLine(line, contentStart: stripPos)
            return
        }
        closeLeaf()
        let code = Block(
            kind: .codeBlock,
            parent: stack[stack.count - 1].block,
            firstLine: Int32(line)
        )
        appendLeaf(code, line: line, contentStart: stripPos)
        openLeaf = Int32(blocks.count - 1)
    }

    // MARK: - Block bookkeeping

    private mutating func appendLeaf(_ block: Block, line: Int, contentStart: Int) {
        blocks.append(block)
        let index = Int32(blocks.count - 1)
        blocks[Int(index)].lineCount = 1
        lines.contentOffsets[line] = UInt16(min(contentStart - lines.start(of: line), 0xFFFF))
        lastConsumedLine = Int32(line)
        markItemHead(index)
    }

    /// The first leaf of a list item is the one the marker is drawn beside.
    private mutating func markItemHead(_ index: Int32) {
        guard stack[stack.count - 1].kind == .listItem || blocks[Int(index)].parent >= 0 else {
            return
        }
        let parent = blocks[Int(index)].parent
        guard parent >= 0, blocks[Int(parent)].kind == .listItem else { return }
        // Only the first child of the item qualifies; any earlier sibling means
        // this is not it.
        for existing in stride(from: Int(index) - 1, through: 0, by: -1) {
            if blocks[existing].parent == parent { return }
            if existing <= Int(parent) { break }
        }
        blocks[Int(index)].flags.insert(.itemHead)
    }

    private mutating func appendLine(_ line: Int, contentStart: Int) {
        guard openLeaf >= 0 else { return }
        lines.contentOffsets[line] = UInt16(
            min(max(contentStart - lines.start(of: line), 0), 0xFFFF))
        let block = Int(openLeaf)
        blocks[block].lineCount = Int32(line) - blocks[block].firstLine + 1
        lastConsumedLine = Int32(line)
    }

    private mutating func push(kind: BlockKind, firstLine: Int) {
        let block = Block(
            kind: kind, parent: stack[stack.count - 1].block, firstLine: Int32(firstLine))
        blocks.append(block)
        stack.append(OpenFrame(block: Int32(blocks.count - 1), kind: kind))
    }

    /// Content resuming after a blank line makes every enclosing list loose.
    private mutating func noteContentAfterBlank() {
        guard blankPending else { return }
        blankPending = false
        for index in stack.indices where stack[index].kind == .list {
            blocks[Int(stack[index].block)].flags.remove(.tight)
        }
    }

    private mutating func closeLeafOnBlank() {
        guard openLeaf >= 0 else { return }
        let kind = blocks[Int(openLeaf)].kind
        // Fenced code keeps blank lines; phase 2 owns it and never gets here.
        if kind == .codeBlock, !blocks[Int(openLeaf)].flags.contains(.fenced) { return }
        closeLeaf()
    }

    private mutating func closeLeaf() {
        guard openLeaf >= 0 else { return }
        if stack.count > 1, stack[stack.count - 1].block == openLeaf { closeTip() }
        openLeaf = -1
    }

    private mutating func closeTip() {
        guard stack.count > 1 else { return }
        let frame = stack.removeLast()
        finish(block: frame.block)
        if frame.block == openLeaf { openLeaf = -1 }
    }

    private mutating func close(to depth: Int) {
        closeLeaf()
        while stack.count > max(depth, 1) { closeTip() }
    }

    private mutating func closeAll() {
        closeLeaf()
        while stack.count > 1 { closeTip() }
        blocks[0].lineCount = Int32(lines.count)
    }

    private mutating func finish(block index: Int32) {
        let block = blocks[Int(index)]
        guard !block.kind.isLeaf else { return }
        blocks[Int(index)].lineCount = max(0, lastConsumedLine - block.firstLine + 1)
    }

    // MARK: - Line predicates

    @inline(__always)
    private func isBlank(from start: Int, to end: Int) -> Bool {
        var index = start
        while index < end {
            if !isSpaceOrTab(bytes[index]) { return false }
            index += 1
        }
        return true
    }

    @inline(__always)
    private func nextTabStop(_ column: Int) -> Int { column + 4 - (column % 4) }

    /// Consume spaces and tabs while staying at or below `limit` columns.
    @inline(__always)
    private func advanceIndent(_ pos: inout Int, _ col: inout Int, limit: Int, end: Int) {
        while pos < end {
            let byte = bytes[pos]
            if byte == ASCII.space {
                if col + 1 > limit { return }
                col += 1
                pos += 1
            } else if byte == ASCII.tab {
                let stop = nextTabStop(col)
                if stop > limit { return }
                col = stop
                pos += 1
            } else {
                return
            }
        }
    }

    private func runLength(from start: Int, to end: Int, of byte: UInt8) -> Int {
        var index = start
        while index < end, bytes[index] == byte { index += 1 }
        return index - start
    }

    private func isRun(from start: Int, to end: Int, of byte: UInt8, minimum: Int) -> Bool {
        let length = runLength(from: start, to: end, of: byte)
        guard length >= minimum else { return false }
        return isBlank(from: start + length, to: end)
    }

    private func isThematicBreak(from start: Int, to end: Int) -> Bool {
        guard start < end else { return false }
        let marker = bytes[start]
        guard marker == ASCII.hyphen || marker == ASCII.asterisk || marker == ASCII.underscore
        else {
            return false
        }
        var count = 0
        var index = start
        while index < end {
            let byte = bytes[index]
            if byte == marker {
                count += 1
            } else if !isSpaceOrTab(byte) {
                return false
            }
            index += 1
        }
        return count >= 3
    }

    private func atxHeadingLevel(at start: Int, lineEnd: Int) -> Int? {
        guard start < lineEnd, bytes[start] == ASCII.hash else { return nil }
        let level = runLength(from: start, to: lineEnd, of: ASCII.hash)
        guard level <= 6 else { return nil }
        let after = start + level
        guard after >= lineEnd || isSpaceOrTab(bytes[after]) else { return nil }
        return level
    }

    /// The heading's text with the leading hashes and an optional closing run
    /// of hashes removed.
    private func atxHeadingText(at start: Int, level: Int, lineEnd: Int) -> ByteRange {
        var textStart = start + level
        while textStart < lineEnd, isSpaceOrTab(bytes[textStart]) { textStart += 1 }
        var textEnd = lineEnd
        while textEnd > textStart, isSpaceOrTab(bytes[textEnd - 1]) { textEnd -= 1 }
        var hashes = textEnd
        while hashes > textStart, bytes[hashes - 1] == ASCII.hash { hashes -= 1 }
        if hashes < textEnd, hashes == textStart {
            textEnd = textStart
        } else if hashes < textEnd, isSpaceOrTab(bytes[hashes - 1]) {
            textEnd = hashes
            while textEnd > textStart, isSpaceOrTab(bytes[textEnd - 1]) { textEnd -= 1 }
        }
        return ByteRange(textStart, textEnd)
    }

    private func setextLevel(at start: Int, lineEnd: Int) -> Int? {
        guard start < lineEnd else { return nil }
        if isRun(from: start, to: lineEnd, of: ASCII.equals, minimum: 1) { return 1 }
        if isRun(from: start, to: lineEnd, of: ASCII.hyphen, minimum: 1) { return 2 }
        return nil
    }

    private struct Fence {
        var character: UInt8
        var length: Int
    }

    private func fenceAt(_ start: Int, lineEnd: Int) -> Fence? {
        guard start < lineEnd else { return nil }
        let character = bytes[start]
        guard character == ASCII.backtick || character == ASCII.tilde else { return nil }
        let length = runLength(from: start, to: lineEnd, of: character)
        guard length >= 3 else { return nil }
        // A backtick fence's info string may not contain a backtick, or the
        // line is a paragraph carrying a long code span.
        if character == ASCII.backtick {
            var index = start + length
            while index < lineEnd {
                if bytes[index] == ASCII.backtick { return nil }
                index += 1
            }
        }
        return Fence(character: character, length: length)
    }

    private func fenceInfo(after start: Int, lineEnd: Int) -> ByteRange {
        var infoStart = start
        while infoStart < lineEnd, isSpaceOrTab(bytes[infoStart]) { infoStart += 1 }
        var infoEnd = infoStart
        // Only the first word is the language; the rest is metadata nobody renders.
        while infoEnd < lineEnd, !isSpaceOrTab(bytes[infoEnd]) { infoEnd += 1 }
        return ByteRange(infoStart, infoEnd)
    }

    /// Does this line start a construct that a lazy paragraph continuation may
    /// not swallow?
    private func startsNewBlock(from start: Int, to end: Int) -> Bool {
        var pos = start
        var col = 0
        advanceIndent(&pos, &col, limit: 3, end: end)
        guard pos < end else { return false }
        if bytes[pos] == ASCII.greaterThan { return true }
        if atxHeadingLevel(at: pos, lineEnd: end) != nil { return true }
        if fenceAt(pos, lineEnd: end) != nil { return true }
        if isThematicBreak(from: pos, to: end) { return true }
        if parseListMarker(at: pos, col: col, lineEnd: end) != nil { return true }
        return false
    }

    // MARK: - Tables

    /// Column count of a GFM delimiter row (`| --- | :-: |`), or nil when the
    /// line is not one.
    private func tableDelimiterColumns(from start: Int, to end: Int) -> Int? {
        var index = start
        var columns = 0
        var sawCell = false
        var sawDash = false
        var leadingPipe = false
        while index < end, isSpaceOrTab(bytes[index]) { index += 1 }
        if index < end, bytes[index] == ASCII.pipe {
            leadingPipe = true
            index += 1
        }
        var cellHasDash = false
        var cellValid = true
        while index < end {
            let byte = bytes[index]
            if byte == ASCII.pipe {
                if !cellHasDash || !cellValid { return nil }
                columns += 1
                cellHasDash = false
                cellValid = true
                sawCell = true
                index += 1
                continue
            }
            if byte == ASCII.hyphen {
                cellHasDash = true
                sawDash = true
            } else if byte != ASCII.colon, !isSpaceOrTab(byte) {
                return nil
            }
            index += 1
        }
        if cellHasDash {
            columns += 1
            sawCell = true
        } else if !leadingPipe || columns == 0 {
            // A trailing pipe closes the last cell; anything else is not a row.
            if !sawCell { return nil }
        }
        guard sawDash, columns > 0 else { return nil }
        return columns
    }

    private func tableCellCount(inLine line: Int) -> Int {
        let range = lines.contentRange(of: line, bytes: bytes)
        return tableCellCount(inLine: line, from: range.lowerBound, to: range.upperBound)
    }

    /// Cells in a table row, honouring backslash escapes and inline code spans
    /// so a pipe inside `` `a|b` `` does not split a cell.
    private func tableCellCount(inLine _: Int, from start: Int, to end: Int) -> Int {
        var index = start
        var cells = 0
        var sawContent = false
        var inCode = false
        var trailingPipe = false
        if index < end, bytes[index] == ASCII.pipe { index += 1 }
        while index < end {
            let byte = bytes[index]
            if byte == ASCII.backslash {
                index += 2
                sawContent = true
                trailingPipe = false
                continue
            }
            if byte == ASCII.backtick { inCode.toggle() }
            if byte == ASCII.pipe, !inCode {
                cells += 1
                trailingPipe = true
            } else if !isSpaceOrTab(byte) {
                sawContent = true
                trailingPipe = false
            }
            index += 1
        }
        if !trailingPipe, sawContent { cells += 1 }
        return cells
    }

    // MARK: - HTML blocks

    private func htmlBlockKind(at start: Int, lineEnd: Int) -> HTMLBlockKind? {
        HTMLBlockScanner.kind(bytes: bytes, start: start, end: lineEnd)
    }

    private func htmlBlockEnds(kind: HTMLBlockKind, from start: Int, to end: Int) -> Bool {
        HTMLBlockScanner.ends(kind: kind, bytes: bytes, start: start, end: end)
    }
}
