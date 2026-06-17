import Foundation

/// Reads Markdown file contents. Kept tiny and synchronous so it is trivially
/// testable; callers run it off the main thread. [REF:fr:open]
enum FileLoader {
    /// Read the file as UTF-8 text. Throws on unreadable / non-UTF-8 files —
    /// fail fast rather than render garbage.
    static func load(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
