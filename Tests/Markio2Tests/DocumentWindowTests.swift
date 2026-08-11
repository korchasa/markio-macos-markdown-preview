import AppKit
import XCTest

@testable import Markio2

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
