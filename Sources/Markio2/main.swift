import AppKit

/// Entry point.
///
/// AppKit is driven directly rather than through `NSApplicationMain` so the
/// menu bar is built before the app finishes launching — a document opened from
/// Finder arrives during launch, and a window that appears before its menus do
/// is the one bug users notice immediately.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
