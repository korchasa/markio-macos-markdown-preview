import Foundation

/// Reads a Markdown file for a host that wants a bounded amount of it.
///
/// The app reads whole documents through `NSDocument` and has no use for this.
/// A preview does: Quick Look runs on a keypress, and pulling a very large file
/// off a slow disk to fill one panel is work nobody asked for. The bound is a
/// courtesy, not a capability limit — the renderer itself is happy with far
/// more.
public enum MarkdownFileReader {
    /// The file's bytes, at most `limit` of them, never cut mid-character.
    ///
    /// Truncating inside a UTF-8 sequence would put a replacement glyph at the
    /// end of an otherwise correct preview, so the tail steps back to the last
    /// complete character.
    public static func read(_ url: URL, limit: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: limit), !data.isEmpty else { return [] }
        var bytes = [UInt8](data)
        guard bytes.count == limit else { return bytes }
        while let last = bytes.last, last & 0b1100_0000 == 0b1000_0000 { bytes.removeLast() }
        if let last = bytes.last, last & 0b1000_0000 != 0 { bytes.removeLast() }
        return bytes
    }
}
