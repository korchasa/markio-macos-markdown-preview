import AppKit
import XCTest

@testable import Markio

/// The menu bar this app builds, and the one macOS adds to it.
@MainActor
final class MenuTests: XCTestCase {
    private func fileMenu() throws -> NSMenu {
        _ = NSApplication.shared
        let main = MainMenu.build()
        return try XCTUnwrap(main.items.first { $0.title == "File" }?.submenu)
    }

    private func menu(_ title: String) throws -> NSMenu {
        _ = NSApplication.shared
        let main = MainMenu.build()
        return try XCTUnwrap(main.items.first { $0.title == title }?.submenu)
    }

    func testClosingEveryDocumentIsOneCommand() throws {
        // One window per document and no tabs: without this, six open reports
        // are six ⌘W.
        let close = try XCTUnwrap(fileMenu().items.first { $0.title == "Close All" })
        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(close.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(close.action, #selector(AppDelegate.closeAllDocuments(_:)))
    }

    func testTheEditMenuIsTheStandardOne() throws {
        // A viewer answers none of these, but a menu missing them reads as an
        // app missing the capability, and the clients that walk the Edit menu
        // expect the standard shape.
        let titles = try menu("Edit").items.map(\.title)
        for expected in ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All"] {
            XCTAssertTrue(titles.contains(expected), "Edit menu has no \(expected)")
        }
    }

    func testCompareKeepsItsShortcut() throws {
        let compare = try XCTUnwrap(fileMenu().items.first { $0.title == "Compare…" })
        XCTAssertEqual(compare.keyEquivalent, "c")
        XCTAssertEqual(compare.keyEquivalentModifierMask, [.command, .shift])
    }

    func testSideBySideSitsUnderView() throws {
        // It lays the document out; it does nothing to the file. The old build
        // kept it next to the Table of Contents and that is where a returning
        // reader looks for it.
        XCTAssertTrue(try menu("View").items.contains { $0.title == "Side by Side" })
        XCTAssertFalse(try fileMenu().items.contains { $0.title == "Side by Side" })
    }

    /// Open Recent is AppKit's to build.
    ///
    /// A document app is given one, filled by `NSDocumentController`. Building
    /// a second put two in the File menu and left the later one empty, and the
    /// guard that removed ours only ran once a person had opened the menu — by
    /// which time the reader had already seen the duplicate.
    func testTheFileMenuLeavesOpenRecentToAppKit() throws {
        XCTAssertTrue(try fileMenu().items.filter { $0.title == "Open Recent" }.isEmpty)
        XCTAssertNil(try fileMenu().delegate)
    }
}
