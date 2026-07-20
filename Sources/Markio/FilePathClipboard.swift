import AppKit

/// Writes a document's exact absolute filesystem path to a native pasteboard.
/// The pasteboard is injectable so tests never touch the user's clipboard.
/// [REF:fr:menu]
@MainActor
struct FilePathClipboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Invalid or unavailable input leaves the existing clipboard untouched.
    @discardableResult
    func copy(_ fileURL: URL?) -> Bool {
        guard let fileURL, fileURL.isFileURL else { return false }
        let path = fileURL.path
        guard path.hasPrefix("/") else { return false }

        pasteboard.clearContents()
        guard pasteboard.setString(path, forType: .string) else {
            Log.app.error("file path pasteboard write failed for \(path)")
            return false
        }
        return true
    }
}
