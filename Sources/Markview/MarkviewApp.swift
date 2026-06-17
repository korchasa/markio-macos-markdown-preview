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
        // Width = default reading column (740) + side margins; height fits a
        // comfortable reading area on a 13" display.
        .defaultSize(width: 900, height: 820)
    }
}

/// Slim AppKit delegate. Finder "Open With", Dock drops, and `open file.md` are
/// handled natively by `DocumentGroup`; the only thing it can't do is honor a
/// path passed on the command line, so we cover `swift run Markview <file>` /
/// `make dev ARGS="<path>"` here. [REF:fr:open]
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One document = one window: opt out of window tabbing app-wide before any
    /// window exists, so documents never merge into tabs regardless of the
    /// system "prefer tabs" setting. [REF:fr:multidoc]
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
            ) { _, _, _ in }
        }
    }
}
