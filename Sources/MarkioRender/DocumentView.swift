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
    /// The diagram shown enlarged, while it is shown.
    private var enlarged: DiagramWindow?

    /// How a written-out diagram reaches a viewer. Named rather than called
    /// straight, so that a test can check the gesture without Preview opening
    /// on somebody's screen.
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The elements published to the system, and the blocks they describe.
    ///
    /// They have to be the same objects from one question to the next. A screen
    /// reader asks the view for its children, then asks each child for its role
    /// and its text; elements built fresh inside every answer are released
    /// before the second question arrives, and the client is left holding eight
    /// children that report nothing at all. That is exactly what the tree
    /// showed before this cache existed.
    var accessibleElements: [NSAccessibilityElement] = []
    var accessibleRange: Range<Int>?

    private struct CodeHover: Equatable {
        var ordinal: Int
        var badgeRect: CGRect
        var language: String
        /// The picture's own rectangle: a click enlarges it, the pointer turns
        /// into a hand over it, and a right-click there offers what can be done
        /// with it.
        var diagramRect: CGRect?
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
    func ordinals(in rect: CGRect) -> Range<Int> {
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

            if let mark = layout.mark(at: ordinal) {
                DocumentRenderer.drawCompareBand(
                    mark: mark,
                    theme: layout.theme,
                    rect: CGRect(x: 0, y: top, width: bounds.width, height: box.height),
                    in: context
                )
            }
            context.saveGState()
            context.translateBy(x: originX, y: top)
            draw(box: box, ordinal: ordinal, selection: selection, in: context)
            context.restoreGState()
        }
        drawStickyTableHeaders(in: context, dirtyRect: dirtyRect)
        drawCodeControls(in: context)
    }

    // MARK: - Tables

    /// Keep a table's header on screen while its rows scroll under it.
    ///
    /// The header is drawn by drawing the whole table again, clipped to the
    /// strip the header occupies and shifted so the header lands at the top of
    /// the viewport. Nothing about tables has to be understood here: whatever
    /// the header row looks like, this is exactly it. The strip disappears with
    /// the table, because the loop only considers tables that are still on
    /// screen.
    private func drawStickyTableHeaders(in context: CGContext, dirtyRect: CGRect) {
        let visible = visibleRect
        guard visible.height > 0 else { return }
        for ordinal in ordinals(in: visible) {
            guard let box = layout.box(at: ordinal), let region = box.tableRegion else { continue }
            let top = layout.offset(of: ordinal) + verticalPadding
            guard
                let strip = DocumentView.stickyHeaderStrip(
                    region: region, blockTop: top, visible: visible, width: bounds.width)
            else { continue }
            guard strip.intersects(dirtyRect) else { continue }
            context.saveGState()
            context.clip(to: strip)
            context.setFillColor(layout.theme.palette.background)
            context.fill(strip)
            context.translateBy(x: contentX, y: strip.minY - region.headerRect.minY)
            draw(box: box, ordinal: ordinal, selection: nil, in: context)
            context.restoreGState()
        }
    }

    /// Where a table's pinned header goes, or nil when it does not need one.
    ///
    /// Nil in both the ordinary cases: the header is still on screen where the
    /// document put it, or the table has scrolled past and taken its header with
    /// it. Pure geometry, so what "disappears with its table" means is one
    /// answer rather than a behaviour spread across a draw call.
    static func stickyHeaderStrip(
        region: BlockBox.TableRegion, blockTop: CGFloat, visible: CGRect, width: CGFloat
    ) -> CGRect? {
        let header = region.headerRect.offsetBy(dx: 0, dy: blockTop)
        let table = region.rect.offsetBy(dx: 0, dy: blockTop)
        guard header.minY < visible.minY else { return nil }
        // Once the bottom of the table is within a header's height of the top of
        // the viewport, there are no rows left to label.
        guard table.maxY > visible.minY + header.height else { return nil }
        return CGRect(x: 0, y: visible.minY, width: width, height: header.height)
    }

    /// A click on a table's header sorts by that column; a click on its filter
    /// row starts typing into it. Returns false when the click was neither, so
    /// the caller can treat it as an ordinary one.
    private func clickTable(at point: CGPoint) -> Bool {
        let ordinal = layout.index(atOffset: max(0, point.y - verticalPadding))
        guard let box = layout.box(at: ordinal), let region = box.tableRegion else {
            endFilterEditing()
            return false
        }
        let top = layout.offset(of: ordinal) + verticalPadding
        if let filter = region.filterRect?.offsetBy(dx: contentX, dy: top), filter.contains(point) {
            layout.filterEditing = ordinal
            needsDisplay = true
            return true
        }
        endFilterEditing()
        guard region.canRearrange else { return false }
        for header in region.headers
        where header.rect.offsetBy(dx: contentX, dy: top).contains(point) {
            layout.clickTableHeader(at: ordinal, column: header.column)
            selectionAnchor = nil
            selectionHead = nil
            needsDisplay = true
            return true
        }
        return false
    }

    private func endFilterEditing() {
        guard layout.filterEditing != nil else { return }
        layout.filterEditing = nil
        needsDisplay = true
    }

    /// Typing while a filter row is active goes into that row, and nowhere
    /// else. Escape gives the keyboard back to the document and clears the
    /// filter, because a filter nobody can see is a table with rows missing.
    public override func keyDown(with event: NSEvent) {
        guard let ordinal = layout.filterEditing else {
            super.keyDown(with: event)
            return
        }
        var arrangement = layout.arrangement(at: ordinal)
        switch event.keyCode {
        case 53:  // Escape
            arrangement.filter = ""
            layout.setArrangement(arrangement, at: ordinal)
            endFilterEditing()
            return
        case 36, 76:  // Return, Enter
            endFilterEditing()
            return
        case 51:  // Delete
            guard !arrangement.filter.isEmpty else { return }
            arrangement.filter.removeLast()
        default:
            guard let typed = event.characters, !typed.isEmpty,
                typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else {
                super.keyDown(with: event)
                return
            }
            arrangement.filter += typed
        }
        layout.setArrangement(arrangement, at: ordinal)
        needsDisplay = true
    }

    // MARK: - Code block controls

    /// The language badge, drawn over the hovered block.
    ///
    /// It lives in the view rather than in the box because it belongs to the
    /// pointer, not to the document: an offscreen render of the same block must
    /// not have a label floating on it. The actions the block offers are in its
    /// context menu, so the badge is a label and never a button.
    private func drawCodeControls(in context: CGContext) {
        guard let hover = hoveredCode else { return }
        let theme = layout.theme
        let copied = copiedOrdinal == hover.ordinal
        guard copied || !hover.language.isEmpty else { return }
        drawPill(
            copied ? "Copied" : hover.language,
            in: hover.badgeRect,
            background: theme.palette.inlineCodeBackground,
            foreground: copied ? theme.palette.link : theme.palette.secondaryText,
            context: context
        )
    }

    /// What the block under the pointer offers, on a right-click.
    ///
    /// The block is found from the event's point and not from `hoveredCode`,
    /// so the menu is right even when the document scrolled under a pointer
    /// that never moved.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hover = codeHover(at: point) else { return nil }
        let menu = NSMenu()
        if hover.diagramRect != nil {
            // What the reader can do with the picture, in the order they are
            // likely to want it: look at it here, look at it in a viewer, take
            // it away with them.
            menu.addItem(command("Enlarge Diagram", #selector(enlargeDiagramCommand(_:)), hover))
            menu.addItem(.separator())
            menu.addItem(command("Open in Preview", #selector(openDiagramCommand(_:)), hover))
            menu.addItem(.separator())
            menu.addItem(command("Copy Diagram as PNG", #selector(copyDiagramCommand(_:)), hover))
            menu.addItem(command("Copy Diagram Source", #selector(copyCodeCommand(_:)), hover))
        } else {
            menu.addItem(command("Copy Code", #selector(copyCodeCommand(_:)), hover))
        }
        return menu
    }

    private func command(_ title: String, _ action: Selector, _ hover: CodeHover) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = hover.ordinal
        return item
    }

    @objc private func copyCodeCommand(_ sender: NSMenuItem) {
        guard let ordinal = sender.representedObject as? Int else { return }
        copyCode(ordinal: ordinal)
    }

    @objc private func copyDiagramCommand(_ sender: NSMenuItem) {
        guard let ordinal = sender.representedObject as? Int else { return }
        copyDiagram(ordinal: ordinal)
    }

    @objc private func enlargeDiagramCommand(_ sender: NSMenuItem) {
        guard let ordinal = sender.representedObject as? Int else { return }
        enlargeDiagram(ordinal: ordinal)
    }

    @objc private func openDiagramCommand(_ sender: NSMenuItem) {
        guard let ordinal = sender.representedObject as? Int else { return }
        openDiagram(ordinal: ordinal)
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
        let badgeWidth = max(34, CGFloat(region.language.count) * 7 + 14)
        let badge = CGRect(
            x: frame.maxX - inset - badgeWidth,
            y: frame.minY + inset,
            width: badgeWidth,
            height: height
        )
        return CodeHover(
            ordinal: ordinal,
            badgeRect: badge,
            language: region.language,
            diagramRect: region.isDiagram ? frame : nil
        )
    }

    /// Open or close the collapsible section whose header was clicked.
    ///
    /// The reader keeps the header they clicked: everything that moves is below
    /// it, so nothing has to be scrolled back afterwards.
    private func toggleSection(at point: CGPoint) -> Bool {
        let ordinal = layout.index(atOffset: max(0, point.y - verticalPadding))
        guard let box = layout.box(at: ordinal), let region = box.disclosureRegion else {
            return false
        }
        let top = layout.offset(of: ordinal) + verticalPadding
        guard region.rect.offsetBy(dx: contentX, dy: top).contains(point) else { return false }
        guard layout.toggleSection(at: ordinal) else { return false }
        selectionAnchor = nil
        selectionHead = nil
        needsDisplay = true
        return true
    }

    /// Put the diagram itself on the clipboard, as a picture.
    private func copyDiagram(ordinal: Int) {
        guard let box = layout.box(at: ordinal),
            let image = DocumentRenderer.diagram(
                source: box.plainText, theme: layout.theme, width: max(640, box.width))
        else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        markCopied(ordinal: ordinal)
    }

    /// Write the diagram out as a PNG at its own size and hand it to whatever
    /// opens PNGs — Preview, on a Mac nobody has changed.
    ///
    /// At its own size and not the column's: the picture the reader wants to
    /// look at properly is the one too big for the page. The bitmap is drawn at
    /// two device pixels per point and says so, so an image viewer showing it
    /// at 100 per cent shows the diagram at exactly the size it was laid out.
    private func openDiagram(ordinal: Int) {
        guard let url = diagramFile(ordinal: ordinal) else { return }
        openFile(url)
    }

    /// The PNG itself, written and ready to hand over. Separate from opening it
    /// so the drawing and the file can be checked without a viewer opening on
    /// somebody's screen.
    func diagramFile(ordinal: Int) -> URL? {
        guard let box = layout.box(at: ordinal) else { return nil }
        let theme = layout.theme.unzoomed
        // Measured first, drawn second: how dense the bitmap should be depends
        // on how large the picture turns out, and a diagram four thousand points
        // across does not want two pixels per point.
        guard
            let measured = DocumentRenderer.diagram(
                source: box.plainText, theme: theme, width: DocumentRenderer.naturalWidth,
                scale: 1)
        else { return nil }
        let size = CGSize(width: CGFloat(measured.width), height: CGFloat(measured.height))
        let density = DocumentRenderer.density(for: size)
        let image =
            density == 1
            ? measured
            : DocumentRenderer.diagram(
                source: box.plainText, theme: theme, width: DocumentRenderer.naturalWidth,
                scale: density)
        guard let image else { return nil }
        return DocumentView.writePNG(
            image, named: diagramName(ordinal: ordinal), density: density)
    }

    /// A name a reader will recognise in a title bar: the document's, the
    /// picture's place in it, and nothing else.
    private func diagramName(ordinal: Int) -> String {
        let document = layout.baseURL?.deletingPathExtension().lastPathComponent ?? "Markio"
        return "\(document) diagram \(ordinal + 1)"
    }

    /// The PNG on disk, at the resolution its density works out to — 144 dots
    /// per inch at two pixels per point — so that the file's own idea of full
    /// size matches the size the diagram was drawn at.
    static func writePNG(_ image: CGImage, named name: String, density: CGFloat = 2) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("png")
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImagePropertyDPIWidth: 72 * density,
                kCGImagePropertyDPIHeight: 72 * density,
            ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    /// Show the hovered diagram large, over the window. A second click on the
    /// same one puts it away again.
    private func enlargeDiagram(ordinal: Int) {
        guard let box = layout.box(at: ordinal), let window else { return }
        if let open = enlarged, open.isVisible, open.source == box.plainText {
            open.close()
            enlarged = nil
            return
        }
        enlarged?.close()
        enlarged = DiagramWindow.present(
            source: box.plainText, theme: layout.theme, over: window,
            onOpenInViewer: { [weak self] in self?.openDiagram(ordinal: ordinal) })
    }

    private func copyCode(ordinal: Int) {
        guard let box = layout.box(at: ordinal) else { return }
        pasteboard.clearContents()
        pasteboard.setString(box.plainText, forType: .string)
        markCopied(ordinal: ordinal)
    }

    private func markCopied(ordinal: Int) {
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

    /// Where Copy writes. The system clipboard, except in a test, which uses
    /// one of its own rather than reaching into the clipboard of whoever is
    /// running the suite.
    public var pasteboard: NSPasteboard = .general

    /// The selection with its styles, ready for an application that can keep
    /// them. Empty when nothing is selected.
    public var selectedRichText: NSAttributedString {
        guard let selection = orderedSelection() else { return NSAttributedString() }
        let result = NSMutableAttributedString()
        for ordinal in selection.start.ordinal...selection.end.ordinal {
            guard let box = layout.box(at: ordinal) else { continue }
            let length = (box.plainText as NSString).length
            let from = ordinal == selection.start.ordinal ? selection.start.offset : 0
            let to = ordinal == selection.end.ordinal ? selection.end.offset : length
            let piece = RichText.block(box: box, from: from, to: to, theme: layout.theme)
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(piece)
        }
        return result
    }

    /// Copy the selection in both flavours.
    ///
    /// The rich one is what Mail, Notes and TextEdit take; the plain one is
    /// character for character what this wrote before there was a rich one, so
    /// a paste into a code editor or a shell is unchanged.
    @objc public func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        let rich = selectedRichText
        pasteboard.clearContents()
        // Richest first: the order these are written is the order an
        // application chooses from, and only RTFD carries a diagram's picture.
        if let rtfd = RichText.rtfd(rich) {
            pasteboard.setData(rtfd, forType: .rtfd)
        }
        if let rtf = RichText.rtf(rich) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(text, forType: .string)
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
        refreshHoverUnderPointer()
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hover = codeHover(at: point)
        if hover != hoveredCode {
            hoveredCode = hover
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        let found = link(at: point)
        if found?.destination != hoveredLink?.destination {
            hoveredLink = found
            window?.invalidateCursorRects(for: self)
        }
        applyCursor()
    }

    /// A hand over anything a click answers — a link, and a diagram, which is
    /// the one picture in the column that opens when clicked.
    private func applyCursor() {
        if wantsPointingHand {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private var wantsPointingHand: Bool {
        hoveredLink != nil || hoveredCode?.diagramRect != nil
    }

    /// Scrolling moves the document under a pointer that did not move, so the
    /// block beneath it changes without a `mouseMoved` ever arriving. Without
    /// this the badge and the pointer keep describing the block that used to be
    /// there — which is why they looked as though they worked only sometimes.
    private func refreshHoverUnderPointer() {
        guard let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return }
        let hover = codeHover(at: point)
        guard hover != hoveredCode else { return }
        hoveredCode = hover
        needsDisplay = true
        window.invalidateCursorRects(for: self)
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
        // A diagram has no text to select, so a click on one shows it large.
        // Opening it in a viewer is a double click on the enlarged picture,
        // where nothing else is competing for the gesture.
        if let hover = hoveredCode, let diagram = hover.diagramRect, diagram.contains(point) {
            if event.clickCount == 1 { enlargeDiagram(ordinal: hover.ordinal) }
            return
        }
        if event.clickCount == 1, let link = link(at: point) {
            onActivateLink?(link)
            return
        }
        if event.clickCount == 1, toggleSection(at: point) { return }
        if event.clickCount == 1, clickTable(at: point) { return }
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
        addCursorRect(bounds, cursor: wantsPointingHand ? .pointingHand : .iBeam)
    }
}
