import Foundation

/// Strict UTF-8 Markdown file read — the Quick Look extension's input gate.
/// Fail fast on unreadable files or non-UTF-8 bytes (consistent with the
/// app's `MarkdownDocument`): the extension hands the error to Quick Look,
/// which falls back to the system plain-text preview. [REF:fr:quicklook]
public enum MarkdownFileReader {
    public struct NotUTF8: Error {
        public let url: URL
    }

    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NotUTF8(url: url)
        }
        return text
    }
}
