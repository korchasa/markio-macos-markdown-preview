import AppKit
import XCTest

@testable import Markio

/// `MenuArtifactCleaner` removes only the native New command after SwiftUI has
/// rebuilt a menu, then collapses separators orphaned by that removal. Other
/// menus and native Open/Open Recent items stay untouched. [REF:fr:menu]
@MainActor
final class MenuArtifactCleanerTests: XCTestCase {
    private final class RebuildingMenuDelegate: NSObject, NSMenuDelegate {
        private(set) var didUpdate = false

        func menuNeedsUpdate(_ menu: NSMenu) {
            didUpdate = true
            menu.insertItem(
                NSMenuItem(
                    title: "New",
                    action: #selector(NSDocumentController.newDocument(_:)),
                    keyEquivalent: "n"),
                at: 0)
        }
    }

    private func nativeNew() -> NSMenuItem {
        NSMenuItem(
            title: "New",
            action: #selector(NSDocumentController.newDocument(_:)),
            keyEquivalent: "n")
    }

    func testForwardsMenuUpdateBeforeRemovingNativeNew() {
        let menu = NSMenu(title: "File")
        menu.addItem(
            NSMenuItem(
                title: "Open…",
                action: #selector(NSDocumentController.openDocument(_:)),
                keyEquivalent: "o"))
        let original = RebuildingMenuDelegate()
        let cleaner = MenuArtifactCleaner.Delegate(forwardingTo: original)

        cleaner.menuNeedsUpdate(menu)

        XCTAssertTrue(original.didUpdate, "SwiftUI's update must run first")
        XCTAssertFalse(
            menu.items.contains {
                $0.action == #selector(NSDocumentController.newDocument(_:))
            },
            "Native New added by the original delegate must be removed afterward")
    }

    func testInstallerIsIdempotentAndRepairsDelegateReplacement() throws {
        let mainMenu = NSMenu(title: "Main")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            NSMenuItem(
                title: "Open…",
                action: #selector(NSDocumentController.openDocument(_:)),
                keyEquivalent: "o"))
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let firstOriginal = RebuildingMenuDelegate()
        fileMenu.delegate = firstOriginal
        let installer = MenuArtifactCleaner.Installer()

        installer.install(on: mainMenu)
        let firstProxy = try XCTUnwrap(fileMenu.delegate as? MenuArtifactCleaner.Delegate)
        installer.install(on: mainMenu)

        XCTAssertTrue(fileMenu.delegate === firstProxy, "Repeated install must not nest proxies")

        let replacement = RebuildingMenuDelegate()
        fileMenu.delegate = replacement
        installer.install(on: mainMenu)
        let repairedProxy = try XCTUnwrap(fileMenu.delegate as? MenuArtifactCleaner.Delegate)
        repairedProxy.menuNeedsUpdate(fileMenu)

        XCTAssertFalse(repairedProxy === firstProxy)
        XCTAssertTrue(replacement.didUpdate, "Replacement SwiftUI delegate must be forwarded")
        XCTAssertFalse(
            fileMenu.items.contains {
                $0.action == #selector(NSDocumentController.newDocument(_:))
            })
    }

    func testRemovesNativeNewAndPreservesOpenCommands() {
        let menu = NSMenu(title: "File")
        menu.addItem(.separator())
        menu.addItem(nativeNew())
        menu.addItem(.separator())
        let open = NSMenuItem(
            title: "Open…",
            action: #selector(NSDocumentController.openDocument(_:)),
            keyEquivalent: "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        menu.addItem(open)
        menu.addItem(recent)

        MenuArtifactCleaner.clean(menu)

        XCTAssertEqual(menu.items.map(\.title), ["Open…", "Open Recent"])
        XCTAssertTrue(menu.items.contains { $0 === open })
        XCTAssertTrue(menu.items.contains { $0 === recent })
    }

    func testCollapsesLeadingAndDuplicateSeparators() {
        let menu = NSMenu(title: "File")
        menu.addItem(nativeNew())
        menu.addItem(.separator())  // becomes leading after New removal
        menu.addItem(.separator())  // duplicate → dropped
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
        // After New removal, a separator whose only follower is hidden is trailing.
        let menu = NSMenu(title: "File")
        let hidden = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: "")
        hidden.isHidden = true
        menu.addItem(nativeNew())
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
        menu.addItem(nativeNew())
        menu.addItem(.separator())
        menu.addItem(recent)
        menu.addItem(search)

        MenuArtifactCleaner.clean(menu)

        XCTAssertEqual(menu.items.count, 2, "Submenu/view items must survive")
    }

    func testLeavesMenuWithoutNativeNewUntouched() {
        let menu = NSMenu(title: "Edit")
        let originalItems = [
            NSMenuItem.separator(),
            NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""),
            NSMenuItem.separator(),
            NSMenuItem.separator(),
        ]
        originalItems.forEach(menu.addItem)

        MenuArtifactCleaner.clean(menu)

        XCTAssertEqual(menu.items.count, originalItems.count)
        XCTAssertTrue(zip(menu.items, originalItems).allSatisfy { $0.0 === $0.1 })
    }
}
