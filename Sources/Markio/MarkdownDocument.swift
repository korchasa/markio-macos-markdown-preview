import AppKit
import MarkdownKit
import MarkioRender

/// One open Markdown file.
///
/// Read-only by construction: there is no writing path, so the document is
/// never dirty, never prompts on close, and never offers Save.
///
/// Documents deliberately do *not* opt into concurrent reading. AppKit would
/// then construct the whole document on a background operation queue, which
/// every `@MainActor` member of `NSDocument` traps on under Swift 6 isolation
/// checking. The parse it would move off the main thread costs 69 ms for a
/// 32 MB file — far below what a reader notices, and not worth taking the
/// document out of the main actor to win.
final class MarkdownDocument: NSDocument {
    /// Parsed content and the bytes it came from.
    ///
    /// Held behind a lock rather than in plain properties because
    /// `read(from:)` is declared `nonisolated` by `NSDocument`, so the compiler
    /// will not let it touch main-actor state directly.
    private let storage = ParsedStorage()
    private var watcher: FileWatcher?

    var parsed: MarkdownKit.Document { storage.document }
    /// The bytes as read, for a comparison that diffs the source rather than
    /// the parse.
    var sourceBytes: [UInt8] { storage.bytes }

    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let bytes = [UInt8](data)
        storage.set(bytes: bytes, document: MarkdownKit.Document(bytes: bytes))
    }

    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        throw CocoaError(.featureUnsupported)
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
        startWatching()
    }

    // MARK: - Printing

    /// Print the pages the PDF export would write.
    ///
    /// Routed through `NSDocument` so ⌘P is the system's own Print command,
    /// with its panel, its page setup and its "Save as PDF" — one pagination
    /// behind all three. The margins are set to nothing because the pages
    /// carry their own; letting the print system add a second set would inset
    /// the text twice.
    override func printOperation(withSettings settings: [NSPrintInfo.AttributeKey: Any]) throws
        -> NSPrintOperation
    {
        let info = NSPrintInfo(dictionary: settings)
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let geometry = PageLayout.Geometry(pageSize: info.paperSize, margin: 54)
        let view = PrintableDocument(document: parsed, baseURL: fileURL, geometry: geometry)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = fileURL?.lastPathComponent ?? "Markio"
        return operation
    }

    override func close() {
        watcher = nil
        super.close()
    }

    // MARK: - Live reload

    /// Watch the file and re-parse when something else writes it — the case
    /// that matters is an agent rewriting a report while it is open.
    private func startWatching() {
        guard let url = fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
    }

    private func reloadFromDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let bytes = [UInt8](data)
        // An editor can touch a file without changing it; re-parsing then would
        // throw away the reader's laid-out page for nothing.
        guard bytes != storage.bytes else { return }
        storage.set(bytes: bytes, document: MarkdownKit.Document(bytes: bytes))
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.documentDidReload()
        }
        // An atomic save replaces the file, so the old watch is now pointing at
        // a vnode nobody will write to again.
        startWatching()
    }
}

/// Lock-guarded parse result, written on the loading queue and read on the main
/// thread.
private final class ParsedStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBytes: [UInt8] = []
    private var storedDocument = MarkdownKit.Document(bytes: [])

    var bytes: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return storedBytes
    }

    var document: MarkdownKit.Document {
        lock.lock()
        defer { lock.unlock() }
        return storedDocument
    }

    func set(bytes: [UInt8], document: MarkdownKit.Document) {
        lock.lock()
        defer { lock.unlock() }
        storedBytes = bytes
        storedDocument = document
    }
}
