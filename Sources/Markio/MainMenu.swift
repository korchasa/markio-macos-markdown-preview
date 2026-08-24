import AppKit

/// The menu bar, built in code.
///
/// A read-only viewer's File menu is short and its Edit menu shorter; a nib
/// would be a binary blob carrying items that have to be deleted again. Every
/// item here routes through the responder chain, so the focused window's
/// controller answers without any window bookkeeping.
@MainActor
enum MainMenu {
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
        // Where a clicked path in a report opens. It lives in the app menu
        // rather than in a settings window because it is the only preference
        // this app has that a control on screen cannot carry.
        let editors = NSMenuItem(title: "Open Code Paths In", action: nil, keyEquivalent: "")
        let editorMenu = NSMenu(title: "Open Code Paths In")
        for editor in CodeEditor.allCases {
            let choice = editorMenu.addItem(
                withTitle: editor.title,
                action: #selector(AppDelegate.chooseCodeEditor(_:)),
                keyEquivalent: ""
            )
            choice.representedObject = editor.rawValue
        }
        editors.submenu = editorMenu
        menu.addItem(editors)
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
        // Open Recent is not built here. AppKit gives a document app one of its
        // own and fills it; building a second put two in the File menu, and the
        // one that came second stayed empty. Removing ours when the system's
        // appeared only worked when a person opened the menu, which is to say
        // it worked after the reader had already seen the duplicate.
        menu.addItem(.separator())
        let compare = menu.addItem(
            withTitle: "Compare…",
            action: #selector(DocumentWindowController.compareWithBaseline(_:)),
            keyEquivalent: "c"
        )
        compare.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Stop Comparing",
            action: #selector(DocumentWindowController.stopComparing(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let export = menu.addItem(
            withTitle: "Export as PDF…",
            action: #selector(DocumentWindowController.exportPDF(_:)),
            keyEquivalent: "e"
        )
        export.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Print…",
            action: #selector(NSDocument.printDocument(_:)),
            keyEquivalent: "p"
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
        let closeAll = menu.addItem(
            withTitle: "Close All",
            action: #selector(AppDelegate.closeAllDocuments(_:)),
            keyEquivalent: "w"
        )
        closeAll.keyEquivalentModifierMask = [.command, .option]
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu("Edit")
        // Undo, Redo, Cut, Paste and Delete belong to a menu the system knows:
        // services and the accessibility clients that walk the Edit menu look
        // for them, and a reader reads a missing item as a missing capability
        // rather than as one a viewer has no use for. Nothing in this app
        // answers them, so AppKit's own validation greys every one of them out
        // — which is the honest state for a document that is never written.
        let undo = menu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        undo.isEnabled = false
        let redo = menu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.isEnabled = false
        menu.addItem(.separator())
        let cut = menu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        cut.isEnabled = false
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        let paste = menu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        paste.isEnabled = false
        let delete = menu.addItem(
            withTitle: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )
        delete.isEnabled = false
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
        // ⌘M is Minimize, so the map takes ⌥⌘M beside the outline's ⌥⌘S.
        let map = menu.addItem(
            withTitle: "Document Map",
            action: #selector(DocumentWindowController.toggleDocumentMap(_:)),
            keyEquivalent: "m"
        )
        map.keyEquivalentModifierMask = [.command, .option]
        // Beside the Table of Contents, which is where the old build kept it
        // and where a returning reader looks: both are ways of laying the
        // document out, not things done to the file.
        menu.addItem(
            withTitle: "Side by Side",
            action: #selector(DocumentWindowController.toggleSideBySide(_:)),
            keyEquivalent: ""
        )
        let present = menu.addItem(
            withTitle: "Presentation",
            action: #selector(DocumentWindowController.present(_:)),
            keyEquivalent: "p"
        )
        present.keyEquivalentModifierMask = [.command, .option]
        // ⌥⌘Z rather than the ⌥⌘F the old focus mode had: a reader who knew
        // that shortcut would otherwise press it and get a different feature.
        let zen = menu.addItem(
            withTitle: "Zen Mode",
            action: #selector(DocumentWindowController.toggleZen(_:)),
            keyEquivalent: "z"
        )
        zen.keyEquivalentModifierMask = [.command, .option]
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
