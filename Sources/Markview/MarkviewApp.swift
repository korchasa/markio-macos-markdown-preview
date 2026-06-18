import AppKit
import SwiftUI

/// App entry point. A native document-based app: `DocumentGroup` gives one
/// window per file, plus File ▸ Open / Open Recent, window tabbing, and state
/// restoration for free. [REF:sds:app-shell] [REF:fr:open] [REF:fr:multidoc]
@main
struct MarkviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { configuration in
            ContentView(document: configuration.document, fileURL: configuration.fileURL)
        }
        // First-launch size only; macOS restores each window's frame after that.
        // Wide enough for the default reading column (80 ch) plus margins; height
        // fits a comfortable reading area on a 13" display.
        .defaultSize(width: 900, height: 820)
        .commands { ReadOnlyMenuCommands() }
    }
}

/// Trims the auto-generated `DocumentGroup` menu to a read-only-viewer surface
/// using only the two contractual SwiftUI command groups that hold document-
/// write commands. Everything else (notably the whole Edit menu) is left
/// standard, so macOS auto-disables the inapplicable items on non-editable
/// content and localizes every item for free. Emptying a group leaves a SwiftUI
/// placeholder item — `MenuArtifactCleaner` removes that. [REF:fr:menu]
struct ReadOnlyMenuCommands: Commands {
    var body: some Commands {
        // New — a viewer creates nothing.
        CommandGroup(replacing: .newItem) {}
        // Save/Save As/Duplicate/Rename/Move To/Revert/Share — and, sharing the
        // same group, Close/Close All.
        CommandGroup(replacing: .saveItem) {}
    }
}

/// Slim AppKit delegate. Finder "Open With", Dock drops, and `open file.md` are
/// handled natively by `DocumentGroup`; the only thing it can't do is honor a
/// path passed on the command line, so we cover `swift run Markview <file>` /
/// `make dev ARGS="<path>"` here. [REF:fr:open]
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retains the menu cleaner delegates — `NSMenu.delegate` is weak. [REF:fr:menu]
    private var menuCleaners: [MenuArtifactCleaner.Delegate] = []

    /// One document = one window: opt out of window tabbing app-wide before any
    /// window exists, so documents never merge into tabs regardless of the
    /// system "prefer tabs" setting. [REF:fr:multidoc]
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.menuCleaners = MenuArtifactCleaner.install(on: NSApp.mainMenu)
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
}
