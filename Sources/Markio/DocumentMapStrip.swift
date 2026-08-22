import AppKit
import MarkioRender

/// The strip down the right edge showing the shape of the whole document.
///
/// Four layers on one strip rather than three ribbons competing for the same
/// edge: the structure underneath, then the blocks a comparison changed, then
/// the find matches, then the rectangle showing where the reader is. It grew
/// out of the find overview, which drew only the third of those.
///
/// While comparing, the map belongs to the main pane — the one the reader is
/// reading — exactly as find and the outline do. Two strips would be a
/// different feature and a worse window.
@MainActor
final class DocumentMapStrip: NSView {
    /// Called with the index of the match nearest a click on one of its marks.
    var onSelect: ((Int) -> Void)?
    /// Called with a fraction of the document to scroll to.
    var onScroll: ((CGFloat) -> Void)?
    /// Names the section at a fraction of the document, for the hover tip.
    var onName: ((CGFloat) -> String?)?

    /// How wide the strip is, and the inset the text needs beside it.
    static let width: CGFloat = 14

    private var bins: [DocumentMap.Bin] = []
    private var marks: [CGFloat] = []
    private var current = -1
    private var changes: [(fraction: CGFloat, isAdded: Bool)] = []
    private var reading: ClosedRange<CGFloat> = 0...0
    private var theme: Theme
    private var dragging = false
    private var lastNamed: CGFloat = -1
    private var binnedRows = -1

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    /// The structural background, one entry per row of the strip.
    func setBins(_ bins: [DocumentMap.Bin], rows: Int) {
        self.bins = bins
        binnedRows = rows
        needsDisplay = true
    }

    /// Whether the strip is holding bins for a different height than it now
    /// has — a window resize, or the first bins after it was shown.
    func needsBins(rows: Int) -> Bool { rows != binnedRows }

    /// How many rows the strip wants, in device pixels rather than points, so a
    /// Retina display gets the resolution it can draw.
    var rowCount: Int {
        max(1, Int((bounds.height * (window?.backingScaleFactor ?? 2)).rounded(.down)))
    }

    func setMarks(_ marks: [CGFloat], current: Int) {
        self.marks = marks
        self.current = current
        needsDisplay = true
    }

    func setChanges(_ changes: [(fraction: CGFloat, isAdded: Bool)]) {
        self.changes = changes
        needsDisplay = true
    }

    func setReading(_ range: ClosedRange<CGFloat>) {
        guard range != reading else { return }
        reading = range
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawStructure(in: context)
        drawChanges(in: context)
        drawMarks(in: context)
        drawReading(in: context)
    }

    /// The document itself: one filled row per bin, in the colour of whatever
    /// fills it. A row that also holds something small — one diagram in a wall
    /// of prose — gets a short dash of that colour beside the fill, so a single
    /// picture in a thousand screens of text is still findable.
    private func drawStructure(in context: CGContext) {
        guard !bins.isEmpty, bounds.height > 0 else { return }
        let inset: CGFloat = 2
        let width = bounds.width - inset * 2
        let rowHeight = bounds.height / CGFloat(bins.count)
        for (row, bin) in bins.enumerated() where !bin.isEmpty {
            let rect = CGRect(
                x: inset, y: CGFloat(row) * rowHeight, width: width,
                height: max(rowHeight, 0.5))
            context.setFillColor(theme.mapColor(for: bin.dominant))
            context.fill(rect)
            for kind in DocumentMap.Kind.allCases
            where kind != bin.dominant && bin.has(kind) && DocumentMapStrip.isNotable(kind) {
                // On the left half, so the dash reads as something extra in
                // that row rather than as a row of its own.
                context.setFillColor(theme.mapColor(for: kind))
                context.fill(
                    CGRect(x: inset, y: rect.minY, width: width * 0.4, height: rect.height))
                break
            }
        }
    }

    /// What is worth a dash of its own when it is not what dominates a row: the
    /// things a reader scans a long report for.
    private static func isNotable(_ kind: DocumentMap.Kind) -> Bool {
        switch kind {
        case .diagram, .table, .picture: return true
        case .heading, .prose, .list, .code, .quote, .rule: return false
        }
    }

    private func drawChanges(in context: CGContext) {
        guard !changes.isEmpty else { return }
        let height: CGFloat = 2
        let usable = max(1, bounds.height - height)
        for change in changes {
            context.setFillColor(
                change.isAdded
                    ? theme.palette.diffAddedText : theme.palette.diffRemovedText)
            context.fill(
                CGRect(
                    x: 0, y: min(usable, max(0, change.fraction * usable)),
                    width: bounds.width * 0.35, height: height))
        }
    }

    private func drawMarks(in context: CGContext) {
        guard !marks.isEmpty else { return }
        let inset: CGFloat = 3
        let markWidth = bounds.width - inset * 2
        let markHeight: CGFloat = 2.5
        let usable = max(1, bounds.height - markHeight)
        let ordinary = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        let accent = NSColor.controlAccentColor.cgColor

        // Marks are in reading order, so they arrive sorted; anything landing on
        // a row already painted adds nothing but time, and a large document can
        // report six figures of matches.
        var lastY: CGFloat = -10
        for (index, fraction) in marks.enumerated() {
            let y = min(usable, max(0, fraction * usable))
            let isCurrent = index == current
            if !isCurrent, abs(y - lastY) < 1 { continue }
            lastY = y
            context.setFillColor(isCurrent ? accent : ordinary)
            context.fill(CGRect(x: inset, y: y, width: markWidth, height: markHeight))
        }
    }

    /// Where the reader is: an outline rather than a fill, because everything
    /// under it is the point of the strip.
    private func drawReading(in context: CGContext) {
        guard reading.upperBound > reading.lowerBound else { return }
        let top = min(bounds.height, max(0, reading.lowerBound * bounds.height))
        let bottom = min(bounds.height, max(top + 2, reading.upperBound * bounds.height))
        let rect = CGRect(x: 0.5, y: top + 0.5, width: bounds.width - 1, height: bottom - top - 1)
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.08).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
    }

    // MARK: - Pointer

    private func fraction(at point: CGPoint) -> CGFloat {
        guard bounds.height > 0 else { return 0 }
        return min(1, max(0, point.y / bounds.height))
    }

    /// A click on a find mark selects that match, and a click anywhere else
    /// goes to that part of the document.
    ///
    /// The order matters: find behaved this way before the map existed, and a
    /// reader stepping through matches must not lose that to a strip that now
    /// also scrolls.
    override func mouseDown(with event: NSEvent) {
        let position = fraction(at: convert(event.locationInWindow, from: nil))
        if let index = nearestMark(to: position) {
            onSelect?(index)
            return
        }
        dragging = true
        onScroll?(position)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onScroll?(fraction(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    private func nearestMark(to fraction: CGFloat) -> Int? {
        guard !marks.isEmpty, bounds.height > 0 else { return nil }
        // Within four points of the mark, in the strip's own units.
        let tolerance = 4 / bounds.height
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, mark) in marks.enumerated() {
            let distance = abs(mark - fraction)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return bestDistance <= tolerance ? best : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self
            ))
    }

    /// Naming the section under the pointer is what makes the strip readable
    /// rather than decorative: the colours say what a stretch is made of, and
    /// the tip says which part of the document it is.
    override func mouseMoved(with event: NSEvent) {
        let position = fraction(at: convert(event.locationInWindow, from: nil))
        guard abs(position - lastNamed) > 0.002 else { return }
        lastNamed = position
        toolTip = onName?(position)
    }

    override func mouseExited(with event: NSEvent) {
        lastNamed = -1
        toolTip = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
