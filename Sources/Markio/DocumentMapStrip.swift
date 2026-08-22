import AppKit
import MarkioRender

/// The map down the right edge: the document itself, small.
///
/// It is the editors' minimap, and it is one for the same reason they have one
/// — a reader recognises a place in a document by its shape long before they can
/// read a word of it. A wall of prose, a short list, an indented block of code,
/// a heading with two lines under it: all of that survives at one point per
/// column, and none of it survives a colour-coded bar that says only "code here,
/// prose there".
///
/// So the map draws words rather than kinds: for every source line, a small
/// rectangle per run of non-space bytes, at the column the run starts on. Colour
/// still comes from what the block is, but it now tints real text instead of
/// standing in for it.
///
/// Nothing is typeset to do this, which is what makes it affordable on a huge
/// document: only the lines the strip can show are ever read, and when the
/// document is longer than that the map shows a window onto it and slides the
/// window with the reader — again as an editor's minimap does.
///
/// Four layers, in this order: the text, the blocks a comparison changed, the
/// find matches, and the rectangle showing where the reader is.
@MainActor
final class DocumentMapStrip: NSView {
    /// Called with the index of the match nearest a click on one of its marks.
    var onSelect: ((Int) -> Void)?
    /// Called with the leaf the reader clicked on.
    var onGoTo: ((Int) -> Void)?
    /// Names the section at a leaf, for the hover tip.
    var onName: ((Int) -> String?)?

    /// How wide the strip is, and the inset the text needs beside it.
    static let width: CGFloat = 120
    /// One source line. Two points is what an editor's minimap gives a line and
    /// it is about the smallest at which a paragraph still reads as a block.
    private static let rowHeight: CGFloat = 2
    private static let inkHeight: CGFloat = 1.2
    private static let columnWidth: CGFloat = 1
    private static let inset: CGFloat = 4

    private var rows: [DocumentMap.Row] = []
    private var startLine = 0
    private var builtCapacity = -1
    private var builtColumns = -1
    /// Find matches and comparison marks are lines of the source, so they land
    /// on the same axis the rows do and slide with them.
    private var marks: [Int] = []
    private var current = -1
    private var changes: [(line: Int, isAdded: Bool)] = []
    private var reading: ClosedRange<Int> = 0...0
    private var theme: Theme
    private var dragging = false
    private var lastNamed = -1
    /// The pointer is on the strip, so the reader is using it rather than
    /// reading past it.
    private var hovering = false

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

    /// How many lines fit, and how wide a line may be before it wraps.
    var rowCapacity: Int { max(1, Int(bounds.height / DocumentMapStrip.rowHeight)) }
    var columnCount: Int {
        max(8, Int((bounds.width - DocumentMapStrip.inset * 2) / DocumentMapStrip.columnWidth))
    }

    /// Whether the rows on the strip are for a different window than the one it
    /// should now be showing — the reader scrolled, or the window resized.
    func needsRows(from line: Int, capacity: Int, columns: Int) -> Bool {
        line != startLine || capacity != builtCapacity || columns != builtColumns
    }

    func setRows(_ rows: [DocumentMap.Row], startLine: Int, capacity: Int, columns: Int) {
        self.rows = rows
        self.startLine = startLine
        builtCapacity = capacity
        builtColumns = columns
        needsDisplay = true
    }

    func setMarks(lines: [Int], current: Int) {
        marks = lines
        self.current = current
        needsDisplay = true
    }

    func setChanges(_ changes: [(line: Int, isAdded: Bool)]) {
        self.changes = changes
        needsDisplay = true
    }

    func setReading(_ lines: ClosedRange<Int>) {
        guard lines != reading else { return }
        reading = lines
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawText(in: context)
        drawChanges(in: context)
        drawMarks(in: context)
        drawReading(in: context)
    }

    /// How strong the text on the map is when nobody is using the map.
    ///
    /// The strip is beside the page the whole time a document is open, and at
    /// full strength it competes with the words the reader is actually reading.
    /// Pale is enough to recognise a shape by; the pointer brings it back.
    private static let restingStrength: CGFloat = 0.55

    /// The words of the document, gathered by colour so a screenful of lines is
    /// a handful of fills rather than one per word.
    private func drawText(in context: CGContext) {
        guard !rows.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(hovering ? 1 : DocumentMapStrip.restingStrength)
        var byKind: [DocumentMap.Kind: [CGRect]] = [:]
        for (index, row) in rows.enumerated() where !row.isBlank {
            let y = CGFloat(index) * DocumentMapStrip.rowHeight
            guard y < bounds.height else { break }
            for run in row.runs {
                let rect = CGRect(
                    x: DocumentMapStrip.inset + CGFloat(run.column) * DocumentMapStrip.columnWidth,
                    y: y,
                    width: CGFloat(run.length) * DocumentMapStrip.columnWidth,
                    height: DocumentMapStrip.inkHeight)
                byKind[row.kind, default: []].append(rect)
            }
        }
        for (kind, rects) in byKind {
            context.setFillColor(theme.mapColor(for: kind))
            context.fill(rects)
        }
    }

    private func drawChanges(in context: CGContext) {
        guard !changes.isEmpty else { return }
        for change in changes {
            guard let y = y(of: change.line) else { continue }
            context.setFillColor(
                change.isAdded
                    ? theme.palette.diffAddedText : theme.palette.diffRemovedText)
            context.fill(CGRect(x: 1, y: y, width: 3, height: DocumentMapStrip.rowHeight))
        }
    }

    /// A match is a band across the line it is on, which is where it would be if
    /// the reader could read the map.
    private func drawMarks(in context: CGContext) {
        guard !marks.isEmpty else { return }
        let ordinary = NSColor.systemYellow.withAlphaComponent(0.55).cgColor
        let accent = NSColor.controlAccentColor.cgColor
        var lastY: CGFloat = -10
        for (index, line) in marks.enumerated() {
            guard let y = y(of: line) else { continue }
            let isCurrent = index == current
            if !isCurrent, abs(y - lastY) < 1 { continue }
            lastY = y
            context.setFillColor(isCurrent ? accent : ordinary)
            context.fill(
                CGRect(
                    x: DocumentMapStrip.inset, y: y, width: bounds.width - DocumentMapStrip.inset,
                    height: max(2, DocumentMapStrip.rowHeight)))
        }
    }

    /// Where the reader is: a wash rather than a fill, because everything under
    /// it is the point of the strip.
    private func drawReading(in context: CGContext) {
        guard !rows.isEmpty else { return }
        let top = y(clamping: reading.lowerBound)
        let bottom = max(top + 4, y(clamping: reading.upperBound + 1))
        let rect = CGRect(x: 0.5, y: top + 0.5, width: bounds.width - 1, height: bottom - top - 1)
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.08).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
    }

    // MARK: - The line axis

    /// Where a source line sits on the strip, or nil when it is outside the
    /// window the map is currently showing.
    private func y(of line: Int) -> CGFloat? {
        guard let index = rowIndex(of: line) else { return nil }
        let y = CGFloat(index) * DocumentMapStrip.rowHeight
        return y < bounds.height ? y : nil
    }

    /// The same, for the reading rectangle, which must draw an edge even when
    /// the viewport runs off the end of the window.
    private func y(clamping line: Int) -> CGFloat {
        guard let first = rows.first?.line, let last = rows.last?.line else { return 0 }
        if line <= first { return 0 }
        if line > last { return bounds.height }
        return y(of: line) ?? bounds.height
    }

    /// One row to a line, so this is arithmetic rather than a search — and the
    /// reason the map clips a long line instead of wrapping it.
    private func rowIndex(of line: Int) -> Int? {
        let index = line - startLine
        return index >= 0 && index < rows.count ? index : nil
    }

    private func row(at point: CGPoint) -> DocumentMap.Row? {
        let index = Int(point.y / DocumentMapStrip.rowHeight)
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    /// The leaf a click lands on. A blank line belongs to no block, so the click
    /// takes the next one that does rather than doing nothing.
    private func ordinal(at point: CGPoint) -> Int? {
        var index = Int(point.y / DocumentMapStrip.rowHeight)
        guard index >= 0, index < rows.count else { return nil }
        while index < rows.count, rows[index].ordinal < 0 { index += 1 }
        return index < rows.count ? rows[index].ordinal : rows.last?.ordinal
    }

    // MARK: - Pointer

    /// A click on a find mark selects that match, and a click anywhere else goes
    /// to that part of the document.
    ///
    /// The order matters: find behaved this way before the map existed, and a
    /// reader stepping through matches must not lose that to a strip that now
    /// also scrolls.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = nearestMark(to: point) {
            onSelect?(index)
            return
        }
        dragging = true
        if let ordinal = ordinal(at: point) { onGoTo?(ordinal) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        if let ordinal = ordinal(at: convert(event.locationInWindow, from: nil)) {
            onGoTo?(ordinal)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    private func nearestMark(to point: CGPoint) -> Int? {
        guard !marks.isEmpty else { return nil }
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, line) in marks.enumerated() {
            guard let y = y(of: line) else { continue }
            let distance = abs(y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        // Within four points of the mark, which at this scale is two lines.
        return bestDistance <= 4 ? best : nil
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

    /// Naming the section under the pointer is what makes the map navigable
    /// rather than decorative: the shapes say what a stretch looks like, and the
    /// tip says which part of the document it is.
    override func mouseMoved(with event: NSEvent) {
        guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return }
        guard row.line != lastNamed else { return }
        lastNamed = row.line
        toolTip = row.ordinal >= 0 ? onName?(row.ordinal) : nil
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        lastNamed = -1
        toolTip = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
