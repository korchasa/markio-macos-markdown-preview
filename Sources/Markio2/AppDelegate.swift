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
        if let target = captureTarget() { capture(to: target) }
    }

    /// `--capture=<path>`: draw the window that just opened into a PNG and quit.
    ///
    /// This exists so the real window — scroll view, sidebar, bottom bar and
    /// all — can be checked from a script. It draws the view hierarchy itself
    /// rather than reading the screen, so it needs no recording permission and
    /// works with the window off-screen or behind another app.
    private func captureTarget() -> URL? {
        guard
            let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--capture=") })
        else { return nil }
        return URL(fileURLWithPath: String(argument.dropFirst("--capture=".count)))
    }

    private func capture(to url: URL) {
        // One turn of the run loop, so the document window has laid out and the
        // first visible blocks have been measured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                FileHandle.standardError.write(Data("capture: no visible window\n".utf8))
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                print("captured \(Int(rep.size.width))x\(Int(rep.size.height)) -> \(url.path)")
            }
            NSApp.terminate(nil)
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
///
/// The type lookups stay `nonisolated`: they return a metatype and a constant,
/// touch no state, and AppKit is free to ask for them from whichever queue it
/// happens to be on.
final class MarkdownDocumentController: NSDocumentController {
    override func newDocument(_ sender: Any?) {}

    nonisolated override var documentClassNames: [String] { ["MarkdownDocument"] }

    nonisolated override func documentClass(forType typeName: String) -> AnyClass? {
        MarkdownDocument.self
    }
}
