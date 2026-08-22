import AppKit
import XCTest

@testable import Markio
@testable import MarkioRender

/// The document window itself: how big it opens, and what a drag on its edge is
/// allowed to do to it.
@MainActor
final class DocumentWindowTests: XCTestCase {
    /// Where `windowFrameAutosaveName` keeps the size of the last window.
    private static let autosaveKey = "NSWindow Frame MarkioDocumentWindow"
    private var savedFrame: Any?

    /// Each test opens its window at the size the code chooses, not at the size
    /// the test before it dragged one to — and puts back whatever was there, so
    /// a test run never decides how wide the app opens afterwards.
    override func setUp() {
        super.setUp()
        savedFrame = UserDefaults.standard.object(forKey: Self.autosaveKey)
        UserDefaults.standard.removeObject(forKey: Self.autosaveKey)
    }

    override func tearDown() {
        if let savedFrame {
            UserDefaults.standard.set(savedFrame, forKey: Self.autosaveKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.autosaveKey)
        }
        super.tearDown()
    }

    private func controller() throws -> DocumentWindowController {
        let document = MarkdownDocument()
        try document.read(
            from: Data("# One\n\nTwo paragraphs, so there is something to lay out.\n".utf8),
            ofType: "net.daringfireball.markdown")
        return DocumentWindowController(document: document)
    }

    /// The scroller holding the document, found the way the app's own capture
    /// harness finds it: the one whose document view is the document.
    private func documentScroller(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView, scroller.documentView is DocumentView,
            !scroller.isHidden
        {
            return scroller
        }
        for child in view.subviews {
            if let found = documentScroller(in: child) { return found }
        }
        return nil
    }

    /// Coming back to a document opens it where it was left.
    ///
    /// The restore has two parts and both were wrong at once: the scroll went
    /// through the document view, which does nothing before it has drawn, and
    /// the position was saved again the moment the window appeared — at the top
    /// — so one failed restore erased the memory for good.
    func testAReaderComesBackToWhereTheyLeftTheDocument() throws {
        let url = URL(fileURLWithPath: "/tmp/markio-restore-\(UUID().uuidString).md")
        let text = (0..<300)
            .map { "Paragraph \($0), long enough to take a line of its own." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        document.fileURL = url
        Preferences.setScrollPosition(1500, for: url)

        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)

        let root = try XCTUnwrap(controller.window?.contentView)
        let scroller = try XCTUnwrap(documentScroller(in: root))
        // Straight away: the scroll goes through the clip view, which needs no
        // drawn document view. Asking the document view to scroll itself does
        // nothing at all before it has drawn, and that is what left every
        // reader at the first line.
        XCTAssertEqual(scroller.contentView.bounds.minY, 1500, accuracy: 1)
        // The second half of the restore lands on the next turn of the run
        // loop, once the blocks it scrolled onto have been measured.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(scroller.contentView.bounds.minY, 1500, accuracy: 1)
        // And the position it restored is still the position it remembers.
        XCTAssertEqual(try XCTUnwrap(Preferences.scrollPosition(for: url)), 1500, accuracy: 1)
    }

    /// The map has a lane of its own: the scroller to the right of it, the text
    /// to the left, and neither underneath it.
    ///
    /// Both halves were wrong at once. The strip was pinned to the trailing
    /// edge of the scroll view, where the scroller draws, so it covered the
    /// scroller; and the reading area was told about the strip through
    /// `contentInsets`, which shifts what can be scrolled to without narrowing
    /// the document view — so a document wide enough ran its text under the map.
    func testTheMapTakesALaneOfItsOwnBesideTheScroller() throws {
        let text = (0..<300)
            .map { "Paragraph \($0), long enough to take a line of its own." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()

        let scroller = try XCTUnwrap(documentScroller(in: root))
        let map = try XCTUnwrap(mapStrip(in: root))
        let documentView = try XCTUnwrap(scroller.documentView)
        XCTAssertFalse(map.isHidden, "a document this long is what the map is for")

        let mapFrame = map.convert(map.bounds, to: root)
        let scrollFrame = scroller.convert(scroller.bounds, to: root)
        let textFrame = documentView.convert(documentView.bounds, to: root)

        // A scroller's width of clear space between the map and the edge.
        XCTAssertEqual(
            scrollFrame.maxX - mapFrame.maxX, DocumentWindowController.scrollerLane, accuracy: 1)
        // And the text stops where the map starts, however wide the window is.
        XCTAssertLessThanOrEqual(textFrame.maxX, mapFrame.minX + 1)
        XCTAssertGreaterThan(textFrame.width, 100, "the reading area is still the bulk of it")
    }

    private func mapStrip(in view: NSView) -> DocumentMapStrip? {
        if let strip = view as? DocumentMapStrip { return strip }
        for child in view.subviews {
            if let found = mapStrip(in: child) { return found }
        }
        return nil
    }

    private func window() throws -> NSWindow {
        try XCTUnwrap(try controller().window)
    }

    /// A drag on a window edge reaches the layout as a size constraint at
    /// `dragThatCanResizeWindow`, which is priority 510. Anything the window's
    /// own content asks for above that outranks the drag, and the window stops
    /// moving — which is exactly what two `.defaultHigh` size preferences did.
    func testADragOnTheEdgeOutranksThePreferredSize() throws {
        let window = try window()
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()
        // The preference has to be a preference: the window opens larger than
        // the sizes dragged to below, or the test would prove nothing.
        XCTAssertGreaterThan(content.frame.width, 700)
        XCTAssertGreaterThan(content.frame.height, 500)

        let narrower = content.widthAnchor.constraint(equalToConstant: 700)
        narrower.priority = NSLayoutConstraint.Priority(510)
        narrower.isActive = true
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.width, 700, accuracy: 1)

        let shorter = content.heightAnchor.constraint(equalToConstant: 500)
        shorter.priority = NSLayoutConstraint.Priority(510)
        shorter.isActive = true
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.height, 500, accuracy: 1)
    }

    /// Nothing else in the window asks for a size, so the preference is what the
    /// first window opens at — a lower priority must not cost it that.
    func testTheFirstWindowOpensAtTheReadingSize() throws {
        let window = try window()
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()
        // 810 of reading area and the 30-point bottom bar.
        XCTAssertEqual(content.frame.height, 840, accuracy: 1)
    }

    /// Putting the baseline in a column of its own must not shrink the window.
    ///
    /// The divider between the two columns is a separator box, and a separator
    /// box that has no frame yet reports an intrinsic height of one point and
    /// holds it at 750 — above the window's own size preference at 250. So the
    /// window used to be fitted to that one point and fell to the required
    /// floor: 200 points of reading area over the 30-point bottom bar, a title
    /// bar above a sliver, below even the window's declared minimum of 320. The
    /// store's comparison screenshot came out of that — two columns of content
    /// along the bottom of an empty page.
    func testSideBySideDoesNotCollapseTheWindow() throws {
        let controller = try controller()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()
        let before = content.frame.height
        XCTAssertGreaterThan(before, 500, "the window has to start tall to prove anything")

        let baseline = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        try Data("# One\n\nOne paragraph, so the two versions differ.\n".utf8).write(to: baseline)
        defer { try? FileManager.default.removeItem(at: baseline) }

        controller.compare(with: baseline, sideBySide: true)
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.height, before, accuracy: 1)
    }
}
