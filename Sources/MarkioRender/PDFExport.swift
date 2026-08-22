import AppKit
import CoreText
import MarkdownKit

/// Writing the document out as a PDF, and printing the same pages.
///
/// `DocumentRenderer` already draws through one path for the screen and for the
/// offscreen PNG; a PDF context is a third caller of that same code. Because
/// CoreText draws real glyphs and a diagram is a `CGPath`, what comes out has
/// selectable text and vector diagrams — a web-based renderer prints its
/// diagrams as bitmaps, and this is the cheapest place where "no web engine"
/// turns into something a reader can hold.
@MainActor
public enum PDFExport {
    /// A page of the size the reader's printer is set up for, with a margin
    /// wide enough to be bound or held.
    public static func defaultGeometry() -> PageLayout.Geometry {
        let paper = NSPrintInfo.shared.paperSize
        let size = paper.width > 100 ? paper : CGSize(width: 612, height: 792)
        return PageLayout.Geometry(pageSize: size, margin: 54)
    }

    /// Lay the document out for paper.
    ///
    /// A layout of its own, at the page's width and in the light theme with no
    /// zoom: what is on screen belongs to the reader's eyes and the window they
    /// chose, and neither is a property of the document.
    public static func pageLayout(
        document: Document, baseURL: URL?, geometry: PageLayout.Geometry
    ) -> DocumentLayout {
        let layout = DocumentLayout(
            document: document,
            theme: Theme(isDark: false),
            columnWidth: geometry.contentWidth,
            baseURL: baseURL
        )
        layout.showsTableFilters = false
        return layout
    }

    /// Write `document` to `url` as a PDF.
    ///
    /// - Returns: how many pages were written.
    @discardableResult
    public static func write(
        document: Document,
        baseURL: URL?,
        to url: URL,
        title: String,
        geometry: PageLayout.Geometry = defaultGeometry()
    ) throws -> Int {
        let layout = pageLayout(document: document, baseURL: baseURL, geometry: geometry)
        let pages = PageLayout.paginate(layout: layout, geometry: geometry)
        var box = CGRect(origin: .zero, size: geometry.pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title]
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ExportError.cannotWrite(url)
        }
        for page in pages {
            context.beginPDFPage(nil)
            draw(page: page, layout: layout, geometry: geometry, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return pages.count
    }

    public enum ExportError: Error, CustomStringConvertible {
        case cannotWrite(URL)

        public var description: String {
            switch self {
            case .cannotWrite(let url): return "cannot write a PDF to \(url.path)"
            }
        }
    }

    /// Draw one page into a context whose origin is the page's bottom-left,
    /// which is where both a PDF context and a print context put it.
    ///
    /// The renderer draws downward from a block's top-left corner, so the whole
    /// page is flipped once here rather than every block being taught two
    /// coordinate systems.
    public static func draw(
        page: PageLayout.Page,
        layout: DocumentLayout,
        geometry: PageLayout.Geometry,
        in context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(layout.theme.palette.background)
        context.fill(CGRect(origin: .zero, size: geometry.pageSize))
        context.translateBy(x: geometry.margin, y: geometry.pageSize.height - geometry.margin)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for slice in page.slices {
            guard let box = layout.box(at: slice.ordinal) else { continue }
            context.saveGState()
            context.translateBy(x: 0, y: slice.y)
            context.clip(
                to: CGRect(
                    x: -geometry.margin, y: 0, width: geometry.pageSize.width,
                    height: slice.height + 0.5))
            if slice.scale != 1 { context.scaleBy(x: slice.scale, y: slice.scale) }
            // A slice starting part-way down its block is drawn by moving the
            // block up: the clip above keeps the rest of it off this page.
            context.translateBy(x: 0, y: -slice.from)
            DocumentRenderer.draw(box: box, highlights: [], in: context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}

/// The view AppKit prints through.
///
/// It exists so printing and exporting share one pagination: the print system
/// asks for a page count and then for one page at a time, which is exactly the
/// shape `PageLayout` already produces.
@MainActor
public final class PrintableDocument: NSView {
    private let layout: DocumentLayout
    private let geometry: PageLayout.Geometry
    private let pages: [PageLayout.Page]

    public init(document: Document, baseURL: URL?, geometry: PageLayout.Geometry) {
        self.geometry = geometry
        self.layout = PDFExport.pageLayout(
            document: document, baseURL: baseURL, geometry: geometry)
        self.pages = PageLayout.paginate(layout: layout, geometry: geometry)
        super.init(
            frame: CGRect(
                origin: .zero,
                size: CGSize(
                    width: geometry.pageSize.width,
                    height: geometry.pageSize.height * CGFloat(max(1, pages.count)))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code only") }

    public var pageCount: Int { pages.count }

    public override var isFlipped: Bool { false }

    public override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, pages.count))
        return true
    }

    public override func rectForPage(_ number: Int) -> NSRect {
        let index = max(0, number - 1)
        return NSRect(
            x: 0,
            y: CGFloat(index) * geometry.pageSize.height,
            width: geometry.pageSize.width,
            height: geometry.pageSize.height
        )
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let index = Int((dirtyRect.minY / geometry.pageSize.height).rounded())
        guard index >= 0, index < pages.count else { return }
        context.saveGState()
        // Each page is drawn where the print system asked for it, and the page
        // drawing itself works from the page's own bottom-left corner.
        context.translateBy(x: 0, y: CGFloat(index) * geometry.pageSize.height)
        PDFExport.draw(
            page: pages[index], layout: layout, geometry: geometry, in: context)
        context.restoreGState()
    }
}
