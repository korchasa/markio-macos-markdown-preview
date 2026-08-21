import AppKit
import MarkioRender

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
        // A drawing that cannot read a file asks here, and the window showing
        // that document is the one that asks the reader. Routed by folder
        // rather than by which window is in front: the picture belongs to a
        // document, and the reader should be asked over the document it is in.
        FolderAccess.shared.onNeedsGrant = { folder in
            // The call arrives in the middle of drawing a page, and a sheet
            // cannot open there.
            DispatchQueue.main.async {
                let windows = NSApp.windows.compactMap {
                    $0.windowController as? DocumentWindowController
                }
                let owner = windows.first { $0.documentFolder?.path == folder.path }
                (owner ?? windows.first)?.askForFolder(folder)
            }
        }
        for url in launchFiles {
            documentController.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        if let baseline = baselineFromCommandLine() { startComparison(against: baseline) }
        if let target = pdfTarget() { exportPDF(to: target) }
        if let directory = snapshotDirectory() { runSnapshot(into: directory) }
        if let target = captureTarget() { capture(to: target) }
    }

    /// `--snapshot <dir>`: take the store screenshots and quit.
    ///
    /// Two words rather than `--snapshot=<dir>`, because that is the shape the
    /// tooling outside this repository already calls every app it packages
    /// with. What to shoot comes from a plan beside the document — see
    /// `Snapshot`.
    private func snapshotDirectory() -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
            index + 1 < CommandLine.arguments.count
        else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    private func runSnapshot(into directory: URL) {
        guard let document = launchFiles.first else {
            FileHandle.standardError.write(Data("snapshot: no document to shoot\n".utf8))
            exit(1)
        }
        do {
            try Snapshot.run(document: document, into: directory)
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            exit(1)
        }
        NSApp.terminate(nil)
    }

    /// `--compare=<path>`, with `--side-by-side` to give the baseline its own
    /// column. The reader's way in is the Compare panel; this exists so a
    /// comparison can be captured without a hand on the mouse.
    private func baselineFromCommandLine() -> URL? {
        let prefix = "--compare="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let url = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)))
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("no such baseline: \(url.path)\n".utf8))
            return nil
        }
        return url
    }

    private func startComparison(against baseline: URL) {
        let sideBySide = CommandLine.arguments.contains("--side-by-side")
        for window in NSApp.windows {
            guard let controller = window.windowController as? DocumentWindowController else {
                continue
            }
            controller.compare(with: baseline, sideBySide: sideBySide)
        }
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
        // `--snapshot <dir>` puts a real, existing path in the argument list
        // that is not a document. The check below would happily open it.
        let snapshotValue = CommandLine.arguments.firstIndex(of: "--snapshot").map { $0 + 1 }
        for (index, path) in CommandLine.arguments.enumerated().dropFirst()
        where !path.hasPrefix("-") && index != snapshotValue {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
                continue
            }
            files.append(url)
        }
        return files
    }

    /// `--export-pdf=<path>`: write the open document out as a PDF and quit.
    ///
    /// The reader's way in is the File menu, where the save panel is also the
    /// permission to write. This exists so the pages can be checked from a
    /// script, the way `--capture` checks the window.
    private func pdfTarget() -> URL? {
        let prefix = "--export-pdf="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        return URL(fileURLWithPath: String(argument.dropFirst(prefix.count)))
    }

    private func exportPDF(to url: URL) {
        guard let document = NSDocumentController.shared.documents.first as? MarkdownDocument
        else {
            FileHandle.standardError.write(Data("export-pdf: no document\n".utf8))
            exit(1)
        }
        do {
            let pages = try PDFExport.write(
                document: document.parsed,
                baseURL: document.fileURL,
                to: url,
                title: document.fileURL?.lastPathComponent ?? "Markio"
            )
            print("exported \(pages) pages -> \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("export-pdf: \(error)\n".utf8))
            exit(1)
        }
        NSApp.terminate(nil)
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

    /// `--capture-click=<x>,<y>`: click once before the shot.
    ///
    /// What a click does — folding a section away — cannot be seen in a still
    /// picture of a document nobody has touched. Same coordinates as the hover.
    private func clickPoint() -> CGPoint? {
        let prefix = "--capture-click="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let parts = argument.dropFirst(prefix.count).split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func sendClick(_ point: CGPoint, to window: NSWindow) {
        guard
            let target = window.contentView?.hitTest(point),
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        else { return }
        target.mouseDown(with: event)
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
            if let point = self.clickPoint(), let window = visible {
                self.sendClick(point, to: window)
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
    /// Close every open document at once.
    ///
    /// One window per document and no tabs means six documents are six ⌘W, and
    /// the File menu of every other reader on this system offers the way out of
    /// that. Nothing is ever unsaved here, so this closes rather than asks.
    @objc func closeAllDocuments(_ sender: Any?) {
        NSDocumentController.shared.closeAllDocuments(
            withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil)
    }

    /// Remember which editor a clicked code path should open in.
    @objc func chooseCodeEditor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let editor = CodeEditor(rawValue: raw)
        else { return }
        Preferences.codeEditor = editor
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchFiles.isEmpty && NSDocumentController.shared.documents.isEmpty
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// The tick beside the editor in use. Answered here rather than set when
    /// the menu is built, so the mark follows the choice without the menu
    /// having to be rebuilt.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(chooseCodeEditor(_:)) else { return true }
        item.state = (item.representedObject as? String) == Preferences.codeEditor.rawValue
            ? .on : .off
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// A document controller that never offers to create a new document: Markio
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
