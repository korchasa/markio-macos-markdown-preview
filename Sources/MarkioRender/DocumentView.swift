import AppKit
import CoreText
import MarkdownKit

/// A position in the rendered document: which block, and how far into its text.
public struct TextPosition: Comparable, Sendable {
    public var ordinal: Int
    /// UTF-16 offset into the block's plain text.
    public var offset: Int

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.ordinal == rhs.ordinal ? lhs.offset < rhs.offset : lhs.ordinal < rhs.ordinal
    }
}

/// Draws the document, and nothing else.
///
/// Only the blocks intersecting the visible rectangle are laid out and drawn.
/// The view's height comes from the height index rather than from any real
/// content, so a document of any size scrolls at the cost of one screen.
@MainActor
public final class DocumentView: NSView {
    public let layout: DocumentLayout
    /// Called when the reader clicks a link. The view never opens anything
    /// itself — where a link goes is the app's decision, not the renderer's.
    public var onActivateLink: ((InlineLink) -> Void)?
    /// Called after a scroll settles, with the ordinal at the top of the view.
    public var onVisibleRangeChange: ((Range<Int>) -> Void)?
    /// Called when the system switches between light and dark.
    public var onAppearanceChange: (() -> Void)?
    /// Called when files are dropped on the view. The view does not open
    /// anything itself, for the same reason it does not follow links.
    public var onOpenFiles: (([URL]) -> Void)?
    /// Whether a dropped file is one this app will open. Without it the view
    /// would advertise a drop it cannot honour.
    public var acceptsFile: ((URL) -> Bool)?

    public var verticalPadding: CGFloat = 28
    public var horizontalMargin: CGFloat = 24

    private var selectionAnchor: TextPosition?
    private var selectionHead: TextPosition?
    private var hoveredLink: InlineLink?
    private var trackingArea: NSTrackingArea?
    private var lastReportedRange: Range<Int>?
    /// Match ranges from the find bar, as (ordinal, utf16 range).
    private var findMatches: [FindMatch] = []
    private var currentMatch: Int = -1
    /// The fenced block the pointer is over, and the pill it can click.
    private var hoveredCode: CodeHover?
    /// The block whose Copy was last pressed, so the pill can say so.
    private var copiedOrdinal: Int?

    private struct CodeHover: Equatable {
        var ordinal: Int
        var copyRect: CGRect
        var badgeRect: CGRect
        var language: String
    }

    public struct FindMatch: Sendable, Equatable {
        public var ordinal: Int
        public var location: Int
        public var length: Int

        public init(ordinal: Int, location: Int, length: Int) {
            self.ordinal = ordinal
            self.location = location
            self.length = length
        }
    }

    public init(layout: DocumentLayout) {
        self.layout = layout
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentView is created in code only") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    // MARK: - Geometry

    /// Left edge of the reading column inside the view.
    public var contentX: CGFloat {
        max(horizontalMargin, (bounds.width - layout.columnWidth) / 2)
    }

    public var documentHeight: CGFloat { layout.totalHeight + verticalPadding * 2 }

    private func documentPoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - contentX, y: point.y - verticalPadding)
    }

    /// Ordinals whose blocks intersect a rectangle in view coordinates.
    private func ordinals(in rect: CGRect) -> Range<Int> {
        let count = layout.blockCount
        guard count > 0 else { return 0..<0 }
        let top = max(0, rect.minY - verticalPadding)
        let bottom = max(0, rect.maxY - verticalPadding)
        let first = layout.index(atOffset: top)
        var last = layout.index(atOffset: bottom)
        // The block at `bottom` starts before it but may extend past; include
        // the next one so a tall block never leaves a gap at the edge.
        last = min(count - 1, last + 1)
        return first..<(last + 1)
    }

    // MARK: - Layout pass

    public override func viewWillDraw() {
        prepareVisibleContent()
        super.viewWillDraw()
    }

    /// Lay out what is about to be drawn, then keep the reader's position.
    private func prepareVisibleContent() {
        guard layout.blockCount > 0 else {
            setFrameHeightIfNeeded(verticalPadding * 2)
            return
        }
        let visible = visibleRect
        let range = ordinals(in: visible.insetBy(dx: 0, dy: -visible.height / 2))
        let anchor = layout.index(atOffset: max(0, visible.minY - verticalPadding))
        let shift = layout.prepare(range: range, anchor: anchor)
        setFrameHeightIfNeeded(documentHeight)

        // Measuring a block above the viewport moves everything below it; undo
        // that movement so the text under the reader's eyes stays put.
        if abs(shift) > 0.01, let clipView = superview as? NSClipView {
            var origin = clipView.bounds.origin
            origin.y += shift
            clipView.setBoundsOrigin(origin)
        }
        if lastReportedRange != range {
            lastReportedRange = range
            onVisibleRangeChange?(range)
        }
    }

    private func setFrameHeightIfNeeded(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        setFrameSize(NSSize(width: frame.width, height: height))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { needsDisplay = true }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(layout.theme.palette.background)
        context.fill(dirtyRect)
        guard layout.blockCount > 0 else { return }

        let originX = contentX
        let selection = orderedSelection()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for ordinal in ordinals(in: dirtyRect) {
            guard let box = layout.box(at: ordinal) else { continue }
            let top = layout.offset(of: ordinal) + verticalPadding
            guard top < dirtyRect.maxY, top + box.height > dirtyRect.minY else { continue }

            context.saveGState()
            context.translateBy(x: originX, y: top)
            draw(box: box, ordinal: ordinal, selection: selection, in: context)
            context.restoreGState()
        }
        drawCodeControls(in: context)
    }

    // MARK: - Code block controls

    /// The language badge and the Copy pill, drawn over the hovered block.
    ///
    /// They live in the view rather than in the box because they belong to the
    /// pointer, not to the document: an offscreen render of the same block must
    /// not have a button floating on it.
    private func drawCodeControls(in context: CGContext) {
        guard let hover = hoveredCode else { return }
        let theme = layout.theme
        let copied = copiedOrdinal == hover.ordinal
        if !hover.language.isEmpty {
            drawPill(
                hover.language,
                in: hover.badgeRect,
                background: theme.palette.inlineCodeBackground,
                foreground: theme.palette.secondaryText,
                context: context
            )
        }
        drawPill(
            copied ? "Copied" : "Copy",
            in: hover.copyRect,
            background: theme.palette.keyboardBackground,
            foreground: copied ? theme.palette.link : theme.palette.secondaryText,
            context: context
        )
    }

    private func drawPill(
        _ text: String,
        in rect: CGRect,
        background: CGColor,
        foreground: CGColor,
        context: CGContext
    ) {
        context.setFillColor(background)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                AttributedBuilder.fontKey: layout.theme.controlLabel,
                AttributedBuilder.colorKey: foreground,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textPosition = CGPoint(
            x: rect.midX - width / 2,
            y: rect.midY + (ascent - descent) / 2
        )
        CTLineDraw(line, context)
    }

    /// Where the badge and the pill sit for a code block under the pointer.
    private func codeHover(at point: CGPoint) -> CodeHover? {
        let ordinal = layout.index(atOffset: max(0, point.y - verticalPadding))
        guard let box = layout.box(at: ordinal), let region = box.codeRegion else { return nil }
        let top = layout.offset(of: ordinal) + verticalPadding
        let frame = region.rect.offsetBy(dx: contentX, dy: top)
        guard frame.insetBy(dx: -4, dy: -4).contains(point) else { return nil }

        let height: CGFloat = 20
        let inset: CGFloat = 6
        let copyWidth: CGFloat = 54
        let copy = CGRect(
            x: frame.maxX - inset - copyWidth,
            y: frame.minY + inset,
            width: copyWidth,
            height: height
        )
        let badgeWidth = max(34, CGFloat(region.language.count) * 7 + 14)
        let badge = CGRect(
            x: copy.minX - 6 - badgeWidth,
            y: copy.minY,
            width: badgeWidth,
            height: height
        )
        return CodeHover(
            ordinal: ordinal,
            copyRect: copy,
            badgeRect: badge,
            language: region.language
        )
    }

    private func copyCode(ordinal: Int) {
        guard let box = layout.box(at: ordinal) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(box.plainText, forType: .string)
        copiedOrdinal = ordinal
        needsDisplay = true
        // Long enough to read, short enough that a second copy still reads as
        // a second copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.copiedOrdinal == ordinal else { return }
            self.copiedOrdinal = nil
            self.needsDisplay = true
        }
    }

    private func draw(
        box: BlockBox,
        ordinal: Int,
        selection: (start: TextPosition, end: TextPosition)?,
        in context: CGContext
    ) {
        var highlights: [DocumentRenderer.Highlight] = []
        if let selection,
            let rects = selectionRects(box: box, ordinal: ordinal, selection: selection)
        {
            highlights.append(
                DocumentRenderer.Highlight(rects: rects, color: layout.theme.palette.selection)
            )
        }
        highlights.append(contentsOf: findHighlights(box: box, ordinal: ordinal))
        DocumentRenderer.draw(box: box, highlights: highlights, in: context)
    }

    private func selectionRects(
        box: BlockBox,
        ordinal: Int,
        selection: (start: TextPosition, end: TextPosition)
    ) -> [CGRect]? {
        guard ordinal >= selection.start.ordinal, ordinal <= selection.end.ordinal else {
            return nil
        }
        let from = ordinal == selection.start.ordinal ? selection.start.offset : 0
        let to = ordinal == selection.end.ordinal ? selection.end.offset : Int.max
        return rects(in: box, from: from, to: to).map { $0.insetBy(dx: 0, dy: -1) }
    }

    private func findHighlights(box: BlockBox, ordinal: Int) -> [DocumentRenderer.Highlight] {
        guard !findMatches.isEmpty else { return [] }
        var result: [DocumentRenderer.Highlight] = []
        for (index, match) in findMatches.enumerated() where match.ordinal == ordinal {
            let color =
                index == currentMatch
                ? layout.theme.palette.findCurrentMatch
                : layout.theme.palette.findMatch
            let rects = rects(in: box, from: match.location, to: match.location + match.length)
                .map { $0.insetBy(dx: -1, dy: -1) }
            if !rects.isEmpty {
                result.append(DocumentRenderer.Highlight(rects: rects, color: color))
            }
        }
        return result
    }

    /// Rectangles covering a range of a block's plain text, across whichever
    /// segments it spans.
    private func rects(in box: BlockBox, from: Int, to: Int) -> [CGRect] {
        var result: [CGRect] = []
        for segment in box.segments where segment.textOffset >= 0 {
            let length = segment.attributed.length
            let segmentStart = segment.textOffset
            let segmentEnd = segmentStart + length
            guard from < segmentEnd, to > segmentStart else { continue }
            let localFrom = max(0, from - segmentStart)
            let localTo = min(length, to - segmentStart)
            guard localTo > localFrom else { continue }
            result += SpanGeometry.rects(
                for: NSRange(location: localFrom, length: localTo - localFrom),
                lines: segment.lines
            )
        }
        return result
    }

    // MARK: - Hit testing

    /// The text position under a point in view coordinates, or nil when the
    /// point is outside the document's text.
    public func position(at point: CGPoint) -> TextPosition? {
        guard layout.blockCount > 0 else { return nil }
        let local = documentPoint(from: point)
        let ordinal = layout.index(atOffset: max(0, local.y))
        guard let box = layout.box(at: ordinal) else { return nil }
        let inBox = CGPoint(x: local.x, y: local.y - layout.offset(of: ordinal))

        var best: (distance: CGFloat, offset: Int)?
        for segment in box.segments where segment.textOffset >= 0 {
            for line in segment.lines {
                let frame = line.frame
                let dy: CGFloat
                if inBox.y < frame.minY {
                    dy = frame.minY - inBox.y
                } else if inBox.y > frame.maxY {
                    dy = inBox.y - frame.maxY
                } else {
                    dy = 0
                }
                let index = CTLineGetStringIndexForPosition(
                    line.line,
                    CGPoint(x: inBox.x - line.origin.x, y: 0)
                )
                let clamped =
                    index == kCFNotFound
                    ? line.range.location
                    : min(max(index, line.range.location), line.range.location + line.range.length)
                let offset = segment.textOffset + clamped
                if best == nil || dy < best!.distance {
                    best = (dy, offset)
                }
            }
        }
        guard let best else { return TextPosition(ordinal: ordinal, offset: 0) }
        return TextPosition(ordinal: ordinal, offset: best.offset)
    }

    public func link(at point: CGPoint) -> InlineLink? {
        guard layout.blockCount > 0 else { return nil }
        let local = documentPoint(from: point)
        let ordinal = layout.index(atOffset: max(0, local.y))
        guard let box = layout.box(at: ordinal) else { return nil }
        return box.link(at: CGPoint(x: local.x, y: local.y - layout.offset(of: ordinal)))
    }

    // MARK: - Selection

    private func orderedSelection() -> (start: TextPosition, end: TextPosition)? {
        guard let anchor = selectionAnchor, let head = selectionHead, anchor != head else {
            return nil
        }
        return anchor < head ? (anchor, head) : (head, anchor)
    }

    public var selectedText: String {
        guard let selection = orderedSelection() else { return "" }
        var out = ""
        for ordinal in selection.start.ordinal...selection.end.ordinal {
            guard let box = layout.box(at: ordinal) else { continue }
            let text = box.plainText as NSString
            let from = ordinal == selection.start.ordinal ? selection.start.offset : 0
            let to = ordinal == selection.end.ordinal ? selection.end.offset : text.length
            let clampedFrom = min(max(0, from), text.length)
            let clampedTo = min(max(clampedFrom, to), text.length)
            if !out.isEmpty { out += "\n\n" }
            out += text.substring(
                with: NSRange(location: clampedFrom, length: clampedTo - clampedFrom))
        }
        return out
    }

    public func selectAll() {
        guard layout.blockCount > 0 else { return }
        selectionAnchor = TextPosition(ordinal: 0, offset: 0)
        let last = layout.blockCount - 1
        let length = (layout.box(at: last)?.plainText as NSString?)?.length ?? 0
        selectionHead = TextPosition(ordinal: last, offset: length)
        needsDisplay = true
    }

    public override func selectAll(_ sender: Any?) { selectAll() }

    public func clearSelection() {
        guard selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        needsDisplay = true
    }

    @objc public func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Find

    public func setFindMatches(_ matches: [FindMatch], current: Int) {
        findMatches = matches
        currentMatch = current
        needsDisplay = true
    }

    /// Scroll a match into view, leaving it a comfortable way down from the top
    /// rather than flush against it.
    public func reveal(ordinal: Int, offset: Int? = nil) {
        guard ordinal >= 0, ordinal < layout.blockCount else { return }
        let top = layout.offset(of: ordinal) + verticalPadding
        let target = max(0, top - visibleRect.height * 0.25)
        scroll(NSPoint(x: 0, y: target))
        needsDisplay = true
    }

    // MARK: - Mouse

    // MARK: - Dropped files

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(from: sender).isEmpty ? [] : .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(from: sender).isEmpty ? [] : .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = droppedFiles(from: sender)
        guard !files.isEmpty else { return false }
        onOpenFiles?(files)
        return true
    }

    private func droppedFiles(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        )
        let urls = (objects as? [URL]) ?? []
        guard let acceptsFile else { return urls }
        return urls.filter(acceptsFile)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hover = codeHover(at: point)
        if hover != hoveredCode {
            hoveredCode = hover
            needsDisplay = true
        }
        let found = link(at: point)
        if found?.destination != hoveredLink?.destination {
            hoveredLink = found
            window?.invalidateCursorRects(for: self)
            if found != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if hoveredCode != nil {
            hoveredCode = nil
            needsDisplay = true
        }
        hoveredLink = nil
        NSCursor.arrow.set()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hover = hoveredCode, hover.copyRect.contains(point) {
            copyCode(ordinal: hover.ordinal)
            return
        }
        if event.clickCount == 1, let link = link(at: point) {
            onActivateLink?(link)
            return
        }
        selectionAnchor = position(at: point)
        selectionHead = selectionAnchor
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        selectionHead = position(at: point)
        needsDisplay = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: hoveredLink == nil ? .iBeam : .pointingHand)
    }
}
