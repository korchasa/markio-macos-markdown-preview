import AppKit
import MarkdownKit

/// One open Markdown file.
///
/// Read-only by construction: there is no writing path, so the document is
/// never dirty, never prompts on close, and never offers Save. Parsing happens
/// in `read(from:)`, which AppKit calls off the main thread, so opening a very
/// large file does not freeze the app that is already running.
@MainActor
final class MarkdownDocument: NSDocument {
    private(set) var parsed = MarkdownKit.Document(bytes: [])
    /// Raw bytes, kept so a live reload can compare against what is on disk
    /// without re-parsing an unchanged file.
    private var sourceBytes: [UInt8] = []
    private var watcher: FileWatcher?

    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let bytes = [UInt8](data)
        let document = MarkdownKit.Document(bytes: bytes)
        MainActor.assumeIsolated {
            self.sourceBytes = bytes
            self.parsed = document
        }
    }

    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        throw CocoaError(.featureUnsupported)
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
        startWatching()
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
        guard bytes != sourceBytes else { return }
        sourceBytes = bytes
        parsed = MarkdownKit.Document(bytes: bytes)
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.documentDidReload()
        }
        // An atomic save replaces the file, so the old watch is now pointing at
        // a vnode nobody will write to again.
        startWatching()
    }
}
