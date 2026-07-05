import AppKit

/// Removes the cosmetic artifacts SwiftUI leaves when `CommandGroup(replacing:)`
/// empties a command group: a disabled, title-less placeholder item (AppKit
/// draws it literally as "NSMenuItem") and the orphaned separators that bounded
/// the removed group. This is purely structural — it matches no selector,
/// identifier, or title, so it is locale- and version-robust. The semantic
/// removal stays in `ReadOnlyMenuCommands` (contractual SwiftUI). [REF:fr:menu]
enum MenuArtifactCleaner {
    /// Interpose a cleaner delegate on every top-level submenu. Returns the
    /// cleaners; the caller must retain them (`NSMenu.delegate` is weak).
    static func install(on mainMenu: NSMenu?) -> [MenuArtifactCleaner.Delegate] {
        guard let mainMenu else { return [] }
        return mainMenu.items.compactMap { top in
            guard let submenu = top.submenu else { return nil }
            let cleaner = Delegate(forwardingTo: submenu.delegate)
            submenu.delegate = cleaner
            clean(submenu)
            return cleaner
        }
    }

    /// Drop placeholder items, then collapse leading/trailing/duplicate
    /// separators left behind.
    static func clean(_ menu: NSMenu) {
        for item in menu.items where isPlaceholder(item) {
            menu.removeItem(item)
        }
        collapseSeparators(menu)
    }

    /// A SwiftUI placeholder: no title, not a separator, and carrying nothing
    /// that could render (no custom view, no submenu, no action). Real empty
    /// items — the Help search field (a view item), Open Recent (a submenu) —
    /// are preserved.
    private static func isPlaceholder(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem
            && item.title.isEmpty
            && item.view == nil
            && item.submenu == nil
            && item.action == nil
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

    /// Wraps SwiftUI's own menu delegate: forwards every call to it, then cleans
    /// once it has rebuilt the menu (SwiftUI re-adds the placeholder on each
    /// open). Forwarding preserves key equivalents and dynamic submenus.
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
