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
        if CommandLine.arguments.contains("--present") { startPresentation() }
        if let target = pdfTarget() { exportPDF(to: target) }
        if let directory = snapshotDirectory() { runSnapshot(into: directory) }
        if let target = captureTarget() { capture(to: target) }
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--dump-menu") }) {
            let path = argument.dropFirst("--dump-menu".count).dropFirst()
            dumpMenu(to: path.isEmpty ? nil : URL(fileURLWithPath: String(path)))
        }
    }

    /// `--dump-menu[=<path>]`: write the menu bar as AppKit has it, and quit.
    ///
    /// Whether a command is *enabled* is a question about the responder chain,
    /// not about the code that built the menu: an item routed to a controller
    /// the chain never reaches is visible and does nothing. `NSMenu.update()`
    /// runs the same validation the menu bar runs when it is opened, so this
    /// prints the answer a person would get by looking, and prints it twice to
    /// show that opening a menu does not add to it.
    private func dumpMenu(to file: URL?) {
        // Long enough for something outside to bring the app to the front: an
        // app launched from a terminal stays behind it, and macOS will not let
        // it steal focus for itself.
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                var out = ""
                // Whether a command is enabled is a question about the active
                // app and its key window, so the answer is only worth anything
                // once this app is both. An app launched from a terminal is
                // neither, and every document command reads as broken then.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderedWindows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                out += "active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")"
                out += " recents=\(NSDocumentController.shared.recentDocumentURLs.count)\n"
                for pass in 1...2 {
                    out += "--- pass \(pass) ---\n"
                    guard let bar = NSApp.mainMenu else { break }
                    for top in bar.items {
                        guard let menu = top.submenu else { continue }
                        menu.update()
                        out += "\(top.title)\n"
                        for item in menu.items {
                            out += AppDelegate.describe(item)
                        }
                    }
                }
                if let file {
                    try? out.write(to: file, atomically: true, encoding: .utf8)
                } else {
                    print(out, terminator: "")
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// One line per item: whether it is on, its shortcut, who would receive it,
    /// and — for a submenu — the identifier AppKit fills it by.
    private static func describe(_ item: NSMenuItem) -> String {
        if item.isSeparatorItem { return "  ----\n" }
        let key = item.keyEquivalent.isEmpty ? "" : " [\(shortcut(for: item))]"
        var target = ""
        if let action = item.action {
            // A disabled item says whether the chain reaches nobody or whether
            // somebody deliberately said no.
            let receiver = NSApp.target(forAction: action, to: item.target, from: item)
            target = " → \(receiver.map { String(describing: type(of: $0)) } ?? "nobody")"
        }
        var submenu = ""
        if let menu = item.submenu {
            menu.update()
            let titles = menu.items.map { $0.isSeparatorItem ? "--" : $0.title }
            let owner = menu.delegate.map { String(describing: type(of: $0)) } ?? "-"
            submenu =
                " {\(menu.identifier?.rawValue ?? "-") via \(owner): "
                + "\(titles.joined(separator: ", "))}"
        }
        return "  \(item.isEnabled ? "on " : "off ")\(item.title)\(key)\(target)\(submenu)\n"
    }

    private static func shortcut(for item: NSMenuItem) -> String {
        var out = ""
        if item.keyEquivalentModifierMask.contains(.control) { out += "⌃" }
        if item.keyEquivalentModifierMask.contains(.option) { out += "⌥" }
        if item.keyEquivalentModifierMask.contains(.shift) { out += "⇧" }
        if item.keyEquivalentModifierMask.contains(.command) { out += "⌘" }
        return out + item.keyEquivalent.uppercased()
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

    /// `--present [--slide=<n>]`: open the deck, so a slide can be captured.
    ///
    /// The reader's way in is the View menu. This is the same road `--compare`
    /// takes: a gesture a script cannot make, made once at launch.
    private func startPresentation() {
        let prefix = "--slide="
        let slide =
            CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
            .flatMap { Int($0.dropFirst(prefix.count)) }.map { $0 - 1 } ?? 0
        // The documents named on the command line open asynchronously, so at
        // this point in launch there is no window to present from yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let controllers = NSApp.windows.compactMap {
                $0.windowController as? DocumentWindowController
            }
            guard let controller = controllers.first else {
                FileHandle.standardError.write(Data("present: no document window\n".utf8))
                return
            }
            controller.present(slide: max(0, slide))
        }
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

    /// `--capture-scroll=<points>`: scroll the document down before the shot.
    ///
    /// Anything that only happens once a document has been scrolled — a table's
    /// header pinned to the top of the viewport — cannot be seen in a picture of
    /// a document sitting at its first line.
    private func scrollOffset() -> CGFloat? {
        let prefix = "--capture-scroll="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
            let offset = Double(argument.dropFirst(prefix.count))
        else { return nil }
        return CGFloat(offset)
    }

    private func scroll(_ window: NSWindow, to offset: CGFloat) {
        guard let root = window.contentView, let scrollView = AppDelegate.scrollView(in: root)
        else { return }
        // The document view has to know its height before a scroll can land,
        // and it only learns it by measuring the blocks it is about to draw —
        // which is what `viewWillDraw` does, and what a clean view never gets
        // asked to do.
        guard let documentView = scrollView.documentView else { return }
        documentView.setNeedsDisplay(documentView.bounds)
        documentView.viewWillDraw()
        documentView.scroll(NSPoint(x: 0, y: offset))
        documentView.displayIfNeeded()
    }

    /// The scroller holding the document the reader is looking at.
    ///
    /// Not simply the first one in the window: the outline sidebar has one of
    /// its own, and the baseline of a comparison has a second document view
    /// that is hidden until there is a comparison to show.
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView, found.documentView is DocumentView, !found.isHidden {
            return found
        }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    /// `--capture-type=<text>`: type into whatever the click just focused.
    ///
    /// A table's filter row shows what it is for only once there is something
    /// in it, and typing is the one way to put it there.
    private func typedText() -> String? {
        let prefix = "--capture-type="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        return String(argument.dropFirst(prefix.count))
    }

    private func sendTyping(_ text: String, to window: NSWindow) {
        guard let target = window.firstResponder else { return }
        for character in text {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: String(character),
                    charactersIgnoringModifiers: String(character),
                    isARepeat: false,
                    keyCode: 0
                )
            else { continue }
            target.keyDown(with: event)
        }
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
        // A timer rather than a block on the main queue, and the difference
        // matters: a main-queue block cannot be interrupted by another one, so
        // anything the app defers with `DispatchQueue.main.async` — the map
        // rebuilding its window of lines after a scroll — would never run
        // before the shot, and the picture would show a state no reader ever
        // sees. A timer fires from the run loop itself, so the nested run loop
        // below drains that work first.
        Timer.scheduledTimer(withTimeInterval: captureDelay(), repeats: false) { _ in
            MainActor.assumeIsolated {
                // The window a viewer would be looking at: the frontmost of the
                // highest layer. A deck sits above the document window it was
                // opened from, and a shot of the document behind it is a picture
                // of the wrong thing — which is exactly what came out before this
                // walked the layers instead of taking the first visible window.
                var visible: NSWindow?
                for window in NSApp.orderedWindows
                where window.isVisible
                    && (visible == nil || window.level.rawValue > visible!.level.rawValue)
                {
                    visible = window
                }
                if let offset = self.scrollOffset(), let window = visible {
                    // Twice, with a turn of the run loop between: the first scroll
                    // measures the blocks it lands on, which is what gives the
                    // document its real height, and only then can the second one
                    // reach the offset that was asked for.
                    self.scroll(window, to: offset)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    self.scroll(window, to: offset)
                    // And once more afterwards, long enough for everything a
                    // scroll defers: the map's window of lines on the next turn,
                    // and the reading position, which is written after a third
                    // of a second of stillness so a drag does not write on
                    // every frame.
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
                if let point = self.hoverPoint(), let window = visible {
                    self.sendHover(point, to: window)
                    window.contentView?.displayIfNeeded()
                }
                if let point = self.clickPoint(), let window = visible {
                    self.sendClick(point, to: window)
                    window.contentView?.displayIfNeeded()
                }
                if let typed = self.typedText(), let window = visible {
                    self.sendTyping(typed, to: window)
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
                // A real quit flushes what the app has written to its defaults;
                // this one happens a fraction of a second after the write, so
                // the reading position of a captured scroll would be lost and
                // the harness could never see it restored.
                UserDefaults.standard.synchronize()
                NSApp.terminate(nil)
            }
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
        item.state =
            (item.representedObject as? String) == Preferences.codeEditor.rawValue
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
