import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let documentController = MarkdownDocumentController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Touching the controller registers it as the shared one, which has to
        // happen before AppKit creates a plain NSDocumentController of its own.
        _ = documentController
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A path on the command line is how `deno task dev` opens a file; the
        // packaged app gets its documents through the normal Apple events.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            documentController.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// A viewer has nothing to show without a document, so a launch with no
    /// file goes straight to the open panel.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.documents.isEmpty
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// A document controller that never offers to create a new document: Markio 2
/// reads Markdown, it does not write it.
@MainActor
final class MarkdownDocumentController: NSDocumentController {
    override func newDocument(_ sender: Any?) {}

    override var documentClassNames: [String] { ["MarkdownDocument"] }

    override func documentClass(forType typeName: String) -> AnyClass? {
        MarkdownDocument.self
    }
}
