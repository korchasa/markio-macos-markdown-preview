import AppKit

/// Removes the native New item that the tested SwiftUI runtime supplies despite
/// `DocumentGroup(viewing:)`. Commands and Open Recent remain SwiftUI-owned;
/// this adapter matches only AppKit's public document action. [REF:fr:menu]
enum MenuArtifactCleaner {
    /// Keeps one forwarding delegate per current top-level submenu. SwiftUI
    /// may restore its delegate as scenes change, so each install repairs that
    /// replacement without wrapping an already-installed proxy.
    final class Installer {
        private var delegates: [ObjectIdentifier: Delegate] = [:]

        func install(on mainMenu: NSMenu?) {
            guard let mainMenu else { return }
            var activeMenus = Set<ObjectIdentifier>()

            for topItem in mainMenu.items {
                guard let submenu = topItem.submenu else { continue }
                let menuID = ObjectIdentifier(submenu)
                activeMenus.insert(menuID)

                if let existing = delegates[menuID], submenu.delegate === existing {
                    MenuArtifactCleaner.clean(submenu)
                    continue
                }

                let cleaner = Delegate(forwardingTo: submenu.delegate)
                delegates[menuID] = cleaner
                submenu.delegate = cleaner
                MenuArtifactCleaner.clean(submenu)
            }

            delegates = delegates.filter { activeMenus.contains($0.key) }
        }
    }

    /// Drop native New, then collapse only separators orphaned by that removal.
    /// Menus without the exact public action remain byte-for-byte untouched.
    static func clean(_ menu: NSMenu) {
        let nativeNewItems = menu.items.filter {
            $0.action == #selector(NSDocumentController.newDocument(_:))
        }
        guard !nativeNewItems.isEmpty else { return }

        for item in nativeNewItems {
            menu.removeItem(item)
        }
        collapseSeparators(menu)
    }

    private static func collapseSeparators(_ menu: NSMenu) {
        var previousWasSeparator = true  // treat menu start as a separator
        for item in menu.items {
            if item.isHidden { continue }  // hidden items don't separate anything
            if item.isSeparatorItem {
                if previousWasSeparator {
                    menu.removeItem(item)
                } else {
                    previousWasSeparator = true
                }
            } else {
                previousWasSeparator = false
            }
        }
        // Trailing separators — looking past trailing hidden items.
        while let last = menu.items.last(where: { !$0.isHidden }), last.isSeparatorItem {
            menu.removeItem(last)
        }
    }

    /// Wraps SwiftUI's delegate: forwards its rebuild first, then removes New.
    /// Forwarding preserves key equivalents and dynamic Open Recent contents.
    final class Delegate: NSObject, NSMenuDelegate {
        private weak var original: NSMenuDelegate?

        init(forwardingTo original: NSMenuDelegate?) {
            self.original = original
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            original?.menuNeedsUpdate?(menu)
            MenuArtifactCleaner.clean(menu)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original, original.responds(to: aSelector) { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
