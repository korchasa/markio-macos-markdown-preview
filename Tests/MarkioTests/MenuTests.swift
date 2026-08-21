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

    func testTheFileMenuOffersTheRecentDocuments() throws {
        let file = try fileMenu()
        let recents = file.items.filter { $0.title == "Open Recent" }
        XCTAssertEqual(recents.count, 1)
        // The identifier is the whole mechanism: AppKit fills a submenu that
        // carries it and leaves any other alone.
        XCTAssertEqual(
            recents.first?.submenu?.identifier,
            NSUserInterfaceItemIdentifier("NSRecentDocumentsMenu"))
    }

    func testOurOpenRecentGivesWayToTheOneMacOSAdds() throws {
        // A document app on a recent system is given an Open Recent of its own,
        // and the reader saw the item twice — one of the two empty, because
        // only one of them can carry the identifier that fills it.
        let file = try fileMenu()
        let theirs = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        theirs.submenu = NSMenu(title: "Open Recent")
        file.addItem(theirs)

        file.delegate?.menuNeedsUpdate?(file)

        let recents = file.items.filter { $0.title == "Open Recent" }
        XCTAssertEqual(recents.count, 1)
        XCTAssertTrue(recents.first === theirs)
    }

    func testTheOneWeBuildStaysWhenNobodyElseAddsOne() throws {
        let file = try fileMenu()
        file.delegate?.menuNeedsUpdate?(file)
        XCTAssertEqual(file.items.filter { $0.title == "Open Recent" }.count, 1)
    }
}
