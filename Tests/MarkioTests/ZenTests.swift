import AppKit
import XCTest

@testable import Markio

/// Zen mode: the document with nothing else in the window.
///
/// The two things worth pinning are what it takes away and what it gives back.
/// A mode that leaves one strip behind is not the mode; a mode that comes back
/// having rewritten the reader's preferences is worse than not having it, since
/// the loss outlives the reading.
@MainActor
final class ZenTests: XCTestCase {
    private var savedOutline = true
    private var savedMap = true

    override func setUp() {
        super.setUp()
        savedOutline = Preferences.outlineVisible
        savedMap = Preferences.mapVisible
    }

    override func tearDown() {
        Preferences.outlineVisible = savedOutline
        Preferences.mapVisible = savedMap
        super.tearDown()
    }

    private func controller() throws -> DocumentWindowController {
        let document = MarkdownDocument()
        try document.read(
            from: Data("# One\n\nTwo paragraphs, so there is something to lay out.\n".utf8),
            ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.layoutIfNeeded()
        return controller
    }

    func testZenLeavesNothingInTheWindowButTheDocument() throws {
        Preferences.outlineVisible = true
        let controller = try self.controller()
        controller.setOutline(visible: true)
        XCTAssertTrue(controller.visibleChromeForTesting.contains("outline"))

        controller.setZen(true, fullScreen: false)
        XCTAssertEqual(controller.visibleChromeForTesting, [])
    }

    func testLeavingZenPutsTheWindowBackAsItWas() throws {
        Preferences.outlineVisible = true
        let controller = try self.controller()
        controller.setOutline(visible: true)
        // The map decides whether to show from the document's height against
        // the window's, and neither is settled until something asks. Ask twice,
        // which leaves the preference where it was and the strip in the state
        // this window's document actually calls for.
        controller.toggleDocumentMap(nil)
        controller.toggleDocumentMap(nil)
        let before = controller.visibleChromeForTesting

        controller.setZen(true, fullScreen: false)
        controller.setZen(false, fullScreen: false)
        XCTAssertEqual(controller.visibleChromeForTesting, before)
    }

    /// Zen is a way of looking at one document, not a change to how the reader
    /// likes their windows. A quit in zen must not hand them back an app that
    /// has forgotten the outline they always keep open.
    func testZenDoesNotRewriteThePreferences() throws {
        Preferences.outlineVisible = true
        Preferences.mapVisible = true
        let controller = try self.controller()

        controller.setZen(true, fullScreen: false)
        XCTAssertTrue(Preferences.outlineVisible)
        XCTAssertTrue(Preferences.mapVisible)
        XCTAssertFalse(controller.visibleChromeForTesting.contains("outline"))
    }

    /// Escape leaves the mode, as it does in VS Code.
    func testEscapeLeavesZen() throws {
        let controller = try self.controller()
        controller.setZen(true, fullScreen: false)
        controller.cancelOperation(nil)
        XCTAssertFalse(controller.isZen)
    }
}
