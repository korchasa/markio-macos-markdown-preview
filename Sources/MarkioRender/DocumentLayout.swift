import AppKit
import MarkdownKit

/// The virtualized layout of a whole document.
///
/// Holds a height for every block and a laid-out box for only the few hundred
/// blocks near the viewport. Heights start as estimates and are replaced by
/// measurements as blocks are laid out; the Fenwick index keeps the total and
/// every block's position correct throughout, in logarithmic time per update.
///
/// This is the piece that decides Markio's memory profile. A 100 MB document
/// costs its bytes, its block structure, and one screen of typeset text — not a
/// DOM, not an attributed string of the whole file, not a render tree.
@MainActor
public final class DocumentLayout {
    public private(set) var document: Document
    public private(set) var theme: Theme
    /// Width of the reading column.
    public private(set) var columnWidth: CGFloat
    /// Where the document lives, so images beside it can be found.
    public var baseURL: URL?
    /// The comparison this document is showing, if it is showing one.
    ///
    /// The document itself is then the merged source built by `CompareEngine`,
    /// so nothing below this line knows a comparison is in progress; this is
    /// only what lets the view tint the blocks that changed.
    public var comparison: CompareEngine.Result?

    private var heights: HeightIndex
    private var engine: BlockLayoutEngine
    private var boxes: [Int: BlockBox] = [:]
    /// Sections showing their contents, by the ordinal of their `<details>`.
    private var expanded: Set<Int> = []
    /// The ordinals inside a closed section, as sorted, non-overlapping ranges.
    /// Kept as ranges rather than a set of ordinals because a closed section may
    /// hold a hundred thousand blocks, and the question asked of it — "is this
    /// ordinal hidden?" — is asked once per block laid out.
    private var hidden: [Range<Int>] = []
    /// Boxes are kept for the visible range plus this many blocks either side,
    /// so a small scroll never has to lay anything out again.
    private let retainMargin = 40

    public init(document: Document, theme: Theme, columnWidth: CGFloat, baseURL: URL? = nil) {
        self.document = document
        self.theme = theme
        self.columnWidth = max(120, columnWidth)
        self.baseURL = baseURL
        self.engine = BlockLayoutEngine(
            document: document,
            theme: theme,
            width: max(120, columnWidth),
            baseURL: baseURL
        )
        self.heights = HeightIndex(estimates: [])
        resetSections()
        rebuildEstimates()
    }

    // MARK: - Collapsible sections

    /// Which sections are open, back to what the document itself says.
    ///
    /// `<details>` means closed and `<details open>` means open — the author
    /// wrote one or the other on purpose. Answering it costs nothing here
    /// because the pairing was done while the document was parsed.
    private func resetSections() {
        expanded = Set(
            document.disclosures.filter(\.startsExpanded).map(\.open)
        )
        rebuildHidden()
    }

    private func rebuildHidden() {
        var ranges: [Range<Int>] = []
        for section in document.disclosures where !expanded.contains(section.open) {
            let lower = section.open + 1
            let upper = min(document.leaves.count, section.close + 1)
            guard upper > lower else { continue }
            // A nested section inside a closed one is already hidden; merging
            // keeps the list short and the lookup a plain binary search.
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
        }
        hidden = ranges
        engine.expandedSections = Set(expanded.map { document.leaves[$0] })
    }

    /// Sorted, non-overlapping — the shape `isHidden` binary-searches.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int>] = []
        for range in sorted where !range.isEmpty {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// Whether a block is inside a section that is currently closed.
    public func isHidden(_ ordinal: Int) -> Bool {
        var low = 0
        var high = hidden.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = hidden[middle]
            if ordinal < range.lowerBound {
                high = middle - 1
            } else if ordinal >= range.upperBound {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Tables the reader has rearranged

    /// How a table is currently sorted and filtered.
    ///
    /// Keyed by ordinal and held here rather than in the document, because
    /// sorting a table is a way of looking at it: the file keeps the order its
    /// author wrote, and closing the window forgets what the reader did.
    public func arrangement(at ordinal: Int) -> TableArrangement {
        guard ordinal >= 0, ordinal < document.leaves.count else { return TableArrangement() }
        return engine.tableArrangements[document.leaves[ordinal]] ?? TableArrangement()
    }

    public func setArrangement(_ arrangement: TableArrangement, at ordinal: Int) {
        guard ordinal >= 0, ordinal < document.leaves.count else { return }
        let leaf = document.leaves[ordinal]
        if arrangement.isPlain {
            engine.tableArrangements.removeValue(forKey: leaf)
        } else {
            engine.tableArrangements[leaf] = arrangement
        }
        invalidate(ordinal)
    }

    /// The first table in the document, by ordinal.
    ///
    /// A store picture has to arrange a table with nobody clicking it, and
    /// which table it means is the one a reader would reach first.
    public var firstTableOrdinal: Int? {
        document.leaves.firstIndex { document.blocks[Int($0)].kind == .table }
    }

    /// Sort by a column, reverse it, then go back to the author's order.
    public func clickTableHeader(at ordinal: Int, column: Int) {
        setArrangement(arrangement(at: ordinal).clicking(column: column), at: ordinal)
    }

    /// Whether tables offer a filter row.
    ///
    /// A printed page and a slide are not places anyone can type, so they show
    /// the table the document describes and nothing added to it.
    public var showsTableFilters: Bool {
        get { engine.showsTableFilters }
        set {
            guard newValue != engine.showsTableFilters else { return }
            engine.showsTableFilters = newValue
            boxes.removeAll(keepingCapacity: true)
            rebuildEstimates()
        }
    }

    /// The table whose filter row is taking keystrokes, by ordinal.
    public var filterEditing: Int? {
        get { engine.filterEditingTable.flatMap { leaf in document.leaves.firstIndex(of: leaf) } }
        set {
            let leaf = newValue.flatMap { ordinal -> Int32? in
                guard ordinal >= 0, ordinal < document.leaves.count else { return nil }
                return document.leaves[ordinal]
            }
            guard leaf != engine.filterEditingTable else { return }
            let previous = engine.filterEditingTable
            engine.filterEditingTable = leaf
            for changed in [previous, leaf].compactMap({ $0 }) {
                if let ordinal = document.leaves.firstIndex(of: changed) { invalidate(ordinal) }
            }
        }
    }

    /// Drop one block's box so it is laid out again from its current state.
    private func invalidate(_ ordinal: Int) {
        boxes.removeValue(forKey: ordinal)
        heights.setHeight(estimatedHeight(of: ordinal), at: ordinal)
    }

    /// Open or close the section whose `<details>` sits at this ordinal.
    ///
    /// Returns false when that ordinal is not a section header, so a caller can
    /// treat the click as an ordinary one.
    @discardableResult
    public func toggleSection(at ordinal: Int) -> Bool {
        guard let section = document.disclosures.first(where: { $0.open == ordinal }) else {
            return false
        }
        if expanded.contains(ordinal) {
            expanded.remove(ordinal)
        } else {
            expanded.insert(ordinal)
        }
        rebuildHidden()
        // Only the section itself moved. Its header redraws with the triangle
        // the other way round, and every block inside it goes back to an
        // estimate — or to nothing at all, if it is now hidden.
        let range = ordinal...min(document.leaves.count - 1, section.close)
        for inside in range {
            boxes.removeValue(forKey: inside)
            heights.setHeight(estimatedHeight(of: inside), at: inside)
        }
        return true
    }

    private func estimatedHeight(of ordinal: Int) -> CGFloat {
        guard !isHidden(ordinal) else { return 0 }
        return engine.estimatedHeight(for: document.leaves[ordinal], isFirst: ordinal == 0)
    }

    public var blockCount: Int { document.leaves.count }
    public var totalHeight: CGFloat { max(heights.totalHeight, 1) }

    /// How much memory the laid-out boxes are holding right now.
    public var residentLayoutBytes: Int {
        boxes.values.reduce(0) { $0 + $1.footprint }
    }

    public func offset(of ordinal: Int) -> CGFloat { heights.offset(of: ordinal) }
    public func height(of ordinal: Int) -> CGFloat { heights.height(at: ordinal) }
    public func index(atOffset y: CGFloat) -> Int { heights.index(atOffset: y) }

    /// The block whose ordinal owns a given leaf, for jumping to a heading.
    ///
    /// Binary search, not a scan: `leaves` is filled by walking the blocks in
    /// order, so it is strictly increasing. The outline asks this once per
    /// heading, and a 32 MB document holds ~159 000 headings among ~537 000
    /// leaves — scanning turns building the outline into 39 seconds of
    /// quadratic work before the first window appears.
    public func ordinal(ofLeaf leaf: Int32) -> Int? {
        let leaves = document.leaves
        var low = 0
        var high = leaves.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let value = leaves[middle]
            if value == leaf { return middle }
            if value < leaf { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// How a block changed between the two compared versions, if at all.
    ///
    /// A block is judged by its first byte: a block that straddles the boundary
    /// of a change — a list that gained an item, say — belongs to whichever side
    /// it starts on, which is the reading most people expect.
    public func mark(at ordinal: Int) -> CompareEngine.Mark? {
        guard let comparison, ordinal >= 0, ordinal < document.leaves.count else { return nil }
        let range = document.sourceRange(of: document.leaves[ordinal])
        return comparison.mark(atByte: Int(range.start))
    }

    // MARK: - Content changes

    public func replace(document: Document) {
        self.document = document
        boxes.removeAll(keepingCapacity: true)
        engine = BlockLayoutEngine(
            document: document,
            theme: theme,
            width: columnWidth,
            baseURL: baseURL
        )
        resetSections()
        rebuildEstimates()
    }

    public func setColumnWidth(_ width: CGFloat) {
        let clamped = max(120, width)
        guard abs(clamped - columnWidth) > 0.5 else { return }
        columnWidth = clamped
        invalidateLayout()
    }

    public func setTheme(_ theme: Theme) {
        self.theme = theme
        invalidateLayout()
    }

    /// Drop every measurement and box. Heights go back to estimates, which is
    /// correct rather than merely convenient: a width or font change moves
    /// every line in the document, so no old measurement is still true.
    private func invalidateLayout() {
        boxes.removeAll(keepingCapacity: true)
        engine = BlockLayoutEngine(
            document: document,
            theme: theme,
            width: columnWidth,
            baseURL: baseURL
        )
        // Which sections are open is the reader's, not the width's: a change of
        // column must not close what they opened.
        rebuildHidden()
        rebuildEstimates()
    }

    private func rebuildEstimates() {
        var estimates = [Float](repeating: 0, count: document.leaves.count)
        for ordinal in document.leaves.indices {
            estimates[ordinal] = Float(estimatedHeight(of: ordinal))
        }
        heights = HeightIndex(estimates: estimates)
    }

    // MARK: - Boxes

    /// The laid-out box for a block, measuring it if this is its first showing.
    @discardableResult
    public func box(at ordinal: Int) -> BlockBox? {
        guard ordinal >= 0, ordinal < document.leaves.count else { return nil }
        if let existing = boxes[ordinal] { return existing }
        // A block inside a closed section takes no room and draws nothing. It
        // still has a box, so selection, find and copy can go on asking about
        // it in the same way they ask about every other block.
        let box =
            isHidden(ordinal)
            ? BlockBox.empty(leaf: document.leaves[ordinal], width: columnWidth)
            : engine.box(for: document.leaves[ordinal], isFirst: ordinal == 0)
        boxes[ordinal] = box
        heights.setHeight(box.height, at: ordinal)
        return box
    }

    /// Lay out everything in `range`, and report how far the content above it
    /// moved as a result.
    ///
    /// The caller uses that number to keep the block under the reader's eyes
    /// exactly where it was: replacing an estimate with a measurement changes
    /// the offset of everything below it, and doing that silently while someone
    /// scrolls upward is what makes a virtualized view feel broken.
    @discardableResult
    public func prepare(range: Range<Int>, anchor: Int) -> CGFloat {
        let clamped = range.clamped(to: 0..<max(1, document.leaves.count))
        let before = heights.offset(of: anchor)
        for ordinal in clamped { box(at: ordinal) }
        let after = heights.offset(of: anchor)
        evict(keeping: clamped)
        return after - before
    }

    private func evict(keeping range: Range<Int>) {
        guard boxes.count > (range.count + retainMargin * 2) else { return }
        let lower = range.lowerBound - retainMargin
        let upper = range.upperBound + retainMargin
        boxes = boxes.filter { $0.key >= lower && $0.key < upper }
    }
}
