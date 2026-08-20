import AppKit

/// The menu bar, built in code.
///
/// A read-only viewer's File menu is short and its Edit menu shorter; a nib
/// would be a binary blob carrying items that have to be deleted again. Every
/// item here routes through the responder chain, so the focused window's
/// controller answers without any window bookkeeping.
@MainActor
enum MainMenu {
    /// The Open Recent this file builds, kept only for as long as macOS does
    /// not build one itself.
    private static weak var ourRecents: NSMenuItem?

    private static let recentsGuard = RecentsGuard()

    /// Leaves the File menu with one Open Recent on every version of macOS.
    ///
    /// A document app on a recent system is given an Open Recent by AppKit,
    /// and this app builds its own, which is what a Mac without that gift
    /// needs. When both arrive the reader sees the item twice and one of them
    /// is empty, because whichever came second did not get the identifier that
    /// fills it. So the menu is looked at each time it opens, and if the system
    /// has provided one, ours goes.
    final class RecentsGuard: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let ours = ourRecents, menu.items.contains(ours) else { return }
            let theirs = menu.items.contains { $0 !== ours && $0.title == ours.title }
            guard theirs else { return }
            menu.removeItem(ours)
            ourRecents = nil
        }
    }

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        return main
    }

    private static func submenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    private static func appMenu() -> NSMenuItem {
        let name = ProcessInfo.processInfo.processName
        let (item, menu) = submenu(name)
        menu.addItem(
            withTitle: "About \(name)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let hide = menu.addItem(
            withTitle: "Hide \(name)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        menu.addItem(.separator())
        let quit = menu.addItem(
            withTitle: "Quit \(name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let (item, menu) = submenu("File")
        menu.addItem(
            withTitle: "Open…",
            action: #selector(NSDocumentController.openDocument(_:)),
            keyEquivalent: "o"
        )
        let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu(title: "Open Recent")
        // AppKit fills this in as long as it carries the magic identifier.
        recentsMenu.identifier = NSUserInterfaceItemIdentifier("NSRecentDocumentsMenu")
        recents.submenu = recentsMenu
        menu.addItem(recents)
        ourRecents = recents
        menu.delegate = recentsGuard
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Compare…",
            action: #selector(DocumentWindowController.compareWithBaseline(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Side by Side",
            action: #selector(DocumentWindowController.toggleSideBySide(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Stop Comparing",
            action: #selector(DocumentWindowController.stopComparing(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Copy File Path",
            action: #selector(DocumentWindowController.copyFilePath(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu("Edit")
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Find",
            action: #selector(DocumentWindowController.showFind(_:)),
            keyEquivalent: "f"
        )
        menu.addItem(
            withTitle: "Find Next",
            action: #selector(DocumentWindowController.findNext(_:)),
            keyEquivalent: "g"
        )
        let previous = menu.addItem(
            withTitle: "Find Previous",
            action: #selector(DocumentWindowController.findPrevious(_:)),
            keyEquivalent: "g"
        )
        previous.keyEquivalentModifierMask = [.command, .shift]
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu("View")
        let outline = menu.addItem(
            withTitle: "Table of Contents",
            action: #selector(DocumentWindowController.toggleOutline(_:)),
            keyEquivalent: "s"
        )
        outline.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Zoom In",
            action: #selector(DocumentWindowController.zoomIn(_:)),
            keyEquivalent: "+"
        )
        menu.addItem(
            withTitle: "Zoom Out",
            action: #selector(DocumentWindowController.zoomOut(_:)),
            keyEquivalent: "-"
        )
        menu.addItem(
            withTitle: "Actual Size",
            action: #selector(DocumentWindowController.actualSize(_:)),
            keyEquivalent: "0"
        )
        menu.addItem(.separator())
        // The plain ⌘+ and ⌘− belong to zoom, which is what a reader reaches
        // for first and what every other viewer on this system puts there.
        let wider = menu.addItem(
            withTitle: "Wider Column",
            action: #selector(DocumentWindowController.widenColumn(_:)),
            keyEquivalent: "+"
        )
        wider.keyEquivalentModifierMask = [.command, .option]
        let narrower = menu.addItem(
            withTitle: "Narrower Column",
            action: #selector(DocumentWindowController.narrowColumn(_:)),
            keyEquivalent: "-"
        )
        narrower.keyEquivalentModifierMask = [.command, .option]
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu("Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        NSApp.windowsMenu = menu
        return item
    }
}
