import AppKit
import XCTest

@testable import Markio

/// `MenuArtifactCleaner.clean` removes the title-less placeholder SwiftUI leaves
/// after an emptied `CommandGroup` (drawn as "NSMenuItem") and collapses the
/// orphaned separators, while preserving real items — including legitimately
/// title-less ones that carry a view or a submenu. [REF:fr:menu]
@MainActor
final class MenuArtifactCleanerTests: XCTestCase {
    private func placeholder() -> NSMenuItem {
        // What SwiftUI leaves: empty title, no view/submenu/action, not a sep.
        NSMenuItem(title: "", action: nil, keyEquivalent: "")
    }

    func testRemovesPlaceholderAndTrailingSeparators() {
        let menu = NSMenu(title: "File")
        menu.addItem(NSMenuItem(title: "Open…", action: nil, keyEquivalent: ""))
        menu.addItem(placeholder())
        menu.addItem(.separator())

        MenuArtifactCleaner.clean(menu)

        XCTAssertEqual(menu.items.map(\.title), ["Open…"])
    }

    func testCollapsesLeadingAndDuplicateSeparators() {
        let menu = NSMenu(title: "Edit")
        menu.addItem(.separator())  // leading → dropped
        menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())  // between real items → kept (single)
        menu.addItem(.separator())  // duplicate → dropped
        menu.addItem(NSMenuItem(title: "Select All", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())  // trailing → dropped

        MenuArtifactCleaner.clean(menu)

        XCTAssertEqual(
            menu.items.map { $0.isSeparatorItem ? "|" : $0.title },
            ["Copy", "|", "Select All"],
            "Leading/trailing/duplicate separators go; one between real items stays")
    }

    func testTreatsHiddenItemsAsAbsentForSeparators() {
        // A separator whose only follower is a hidden item is still trailing.
        let menu = NSMenu(title: "File")
        let hidden = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: "")
        hidden.isHidden = true
        menu.addItem(NSMenuItem(title: "Open…", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(hidden)

        MenuArtifactCleaner.clean(menu)

        XCTAssertEqual(
            menu.items.filter(\.isSeparatorItem).count, 0,
            "Trailing separator past a hidden item is dropped")
        XCTAssertTrue(menu.items.contains(hidden), "Hidden item itself is preserved")
    }

    func testPreservesViewAndSubmenuItems() {
        let menu = NSMenu(title: "File")
        let recent = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")  // title-less but a submenu
        let search = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        search.view = NSView()  // title-less but a custom view (e.g. Help search)
        menu.addItem(NSMenuItem(title: "Open…", action: nil, keyEquivalent: ""))
        menu.addItem(recent)
        menu.addItem(search)

        MenuArtifactCleaner.clean(menu)

        XCTAssertEqual(menu.items.count, 3, "Submenu/view items must survive")
    }
}
