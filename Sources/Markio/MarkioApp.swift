import AppKit
import SwiftUI

/// App entry point. A native document-based app: `DocumentGroup` gives one
/// window per file, plus File ▸ Open / Open Recent, window tabbing, and state
/// restoration for free. [REF:sds:app-shell] [REF:fr:open] [REF:fr:multidoc]
@main
struct MarkioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { configuration in
            ContentView(document: configuration.document, fileURL: configuration.fileURL)
        }
        // First-launch size only; macOS restores each window's frame after that.
        // Wide enough for the default reading column (80 ch) plus margins; height
        // fits a comfortable reading area on a 13" display.
        .defaultSize(width: 900, height: 820)
        .commands {
            FileCommands()
            FindCommands()
            TOCCommands()
        }
    }
}

/// Slim AppKit delegate. Finder "Open With", Dock drops, and `open file.md` are
/// handled natively by `DocumentGroup`; the only thing it can't do is honor a
/// path passed on the command line, so we cover `swift run Markio <file>` /
/// `make dev ARGS="<path>"` here. [REF:fr:open]
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retains and repairs menu proxies — `NSMenu.delegate` is weak. [REF:fr:menu]
    private let menuCleaner = MenuArtifactCleaner.Installer()

    /// One document = one window: opt out of window tabbing app-wide before any
    /// window exists, so documents never merge into tabs regardless of the
    /// system "prefer tabs" setting. [REF:fr:multidoc]
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Quit always keeps Markio's windows: relaunch reopens the documents
        // that were open at quit (DocumentGroup/AppKit state restoration;
        // sandbox access is system-managed). Written to the app's defaults
        // domain — `register(defaults:)` would lose to the user's global
        // "Close windows when quitting" setting, the app domain overrides it.
        // [REF:fr:session-restore]
        UserDefaults.standard.set(true, forKey: "NSQuitAlwaysKeepsWindows")
    }

    /// Opt into secure state restoration (macOS 14 requirement for restoring
    /// windows without a console warning). [REF:fr:session-restore]
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--snapshot <dir>` renders App Store screenshots offscreen and exits;
        // skip the normal launch path entirely. [REF:fr:open]
        if Snapshot.runIfRequested() { return }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.menuCleaner.install(on: NSApp.mainMenu)
        }
        guard
            let url = CommandLine.arguments
                .dropFirst()
                .map({ URL(fileURLWithPath: $0) })
                .last(where: { $0.isMarkdown })
        else { return }
        // Route through the DocumentController so the file opens in a real
        // DocumentGroup window once the scene is up.
        DispatchQueue.main.async {
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true
            ) { _, _, error in
                if let error {
                    Log.app.error(
                        "command-line open failed for \(url.path): \(error.localizedDescription)")
                }
            }
        }
    }

    /// SwiftUI can restore its own menu delegates while scenes update or the
    /// app activates. Repair before the next menu-tracking cycle. [REF:fr:menu]
    func applicationDidBecomeActive(_ notification: Notification) {
        menuCleaner.install(on: NSApp.mainMenu)
    }

    func applicationDidUpdate(_ notification: Notification) {
        menuCleaner.install(on: NSApp.mainMenu)
    }
}
