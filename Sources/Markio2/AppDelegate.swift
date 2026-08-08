import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let documentController = MarkdownDocumentController()
    private var launchFiles: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Touching the controller registers it as the shared one, which has to
        // happen before AppKit creates a plain NSDocumentController of its own.
        _ = documentController
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = false
        // Quitting always keeps the windows, so a relaunch brings back the
        // documents that were open — a reader who quits mid-report finds it
        // again. Written to the app's own defaults domain on purpose:
        // `register(defaults:)` would lose to the user's global "Close windows
        // when quitting an application", and this app's answer is not a default
        // but a decision.
        UserDefaults.standard.set(true, forKey: "NSQuitAlwaysKeepsWindows")
        launchFiles = filesFromCommandLine()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for url in launchFiles {
            documentController.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        if let target = captureTarget() { capture(to: target) }
    }

    /// Files named on the command line — how `deno task dev` opens a document.
    /// The packaged app gets its documents through the normal Apple events.
    ///
    /// A word that is not a file on disk is reported and skipped rather than
    /// handed to AppKit: the value half of a launch argument
    /// (`-AppleInterfaceStyle Dark`) would otherwise arrive as a document and
    /// stop the app on a modal alert.
    private func filesFromCommandLine() -> [URL] {
        var files: [URL] = []
        for path in CommandLine.arguments.dropFirst() where !path.hasPrefix("-") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
                continue
            }
            files.append(url)
        }
        return files
    }

    /// `--capture=<path>`: draw the window that just opened into a PNG and quit.
    ///
    /// This exists so the real window — scroll view, sidebar, bottom bar and
    /// all — can be checked from a script. It draws the view hierarchy itself
    /// rather than reading the screen, so it needs no recording permission and
    /// works with the window off-screen or behind another app.
    ///
    /// `--capture-after=<seconds>` delays the shot. That is how live reload is
    /// checked: launch with a delay, rewrite the file meanwhile, and the PNG
    /// shows whether the view followed.
    private func captureTarget() -> URL? {
        guard
            let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--capture=") })
        else { return nil }
        return URL(fileURLWithPath: String(argument.dropFirst("--capture=".count)))
    }

    private func captureDelay() -> TimeInterval {
        let prefix = "--capture-after="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
            let seconds = TimeInterval(argument.dropFirst(prefix.count))
        else { return 0.4 }
        return seconds
    }

    /// `--capture-hover=<x>,<y>`: park the pointer before the shot.
    ///
    /// Controls that only appear under the pointer — the Copy pill on a fenced
    /// block — are invisible to a plain capture. The coordinates are the
    /// window's, with the origin at the bottom-left.
    private func hoverPoint() -> CGPoint? {
        let prefix = "--capture-hover="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let parts = argument.dropFirst(prefix.count).split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// A window hands a mouse-moved event to its first responder, not to the
    /// view under the pointer, so a synthesized one has to be delivered to the
    /// view the pointer would really be over.
    private func sendHover(_ point: CGPoint, to window: NSWindow) {
        guard
            let target = window.contentView?.hitTest(point),
            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        else { return }
        target.mouseMoved(with: event)
    }

    private func capture(to url: URL) {
        // At least one turn of the run loop, so the document window has laid
        // out and the first visible blocks have been measured.
        DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay()) {
            let visible = NSApp.windows.first(where: { $0.isVisible })
            if let point = self.hoverPoint(), let window = visible {
                self.sendHover(point, to: window)
                window.contentView?.displayIfNeeded()
            }
            guard let view = visible?.contentView,
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
    ///
    /// AppKit asks this before `applicationDidFinishLaunching` has opened the
    /// files from the command line, so the answer comes from that list rather
    /// than from the documents opened so far — otherwise a launch with a path
    /// races into a modal open panel that nothing can dismiss.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchFiles.isEmpty && NSDocumentController.shared.documents.isEmpty
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
