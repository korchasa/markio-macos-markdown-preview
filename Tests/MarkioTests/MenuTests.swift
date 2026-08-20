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
