import AppKit
import MarkdownKit

/// The virtualized layout of a whole document.
///
/// Holds a height for every block and a laid-out box for only the few hundred
/// blocks near the viewport. Heights start as estimates and are replaced by
/// measurements as blocks are laid out; the Fenwick index keeps the total and
/// every block's position correct throughout, in logarithmic time per update.
///
/// This is the piece that decides Markio 2's memory profile. A 100 MB document
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

    private var heights: HeightIndex
    private var engine: BlockLayoutEngine
    private var boxes: [Int: BlockBox] = [:]
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
        rebuildEstimates()
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
        rebuildEstimates()
    }

    private func rebuildEstimates() {
        var estimates = [Float](repeating: 0, count: document.leaves.count)
        for ordinal in document.leaves.indices {
            estimates[ordinal] = Float(
                engine.estimatedHeight(for: document.leaves[ordinal], isFirst: ordinal == 0)
            )
        }
        heights = HeightIndex(estimates: estimates)
    }

    // MARK: - Boxes

    /// The laid-out box for a block, measuring it if this is its first showing.
    @discardableResult
    public func box(at ordinal: Int) -> BlockBox? {
        guard ordinal >= 0, ordinal < document.leaves.count else { return nil }
        if let existing = boxes[ordinal] { return existing }
        let box = engine.box(for: document.leaves[ordinal], isFirst: ordinal == 0)
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
