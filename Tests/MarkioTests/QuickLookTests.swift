import MarkioEngine
import XCTest

/// Input gate of the Quick Look extension: strict UTF-8 Markdown read, fail
/// fast on anything else so Quick Look falls back to the system preview.
/// [REF:fr:quicklook]
final class QuickLookTests: XCTestCase {
    func testLoadsUTF8MarkdownAndRejectsBinary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickLookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // UTF-8 Markdown (incl. non-ASCII) reads back verbatim.
        let markdown = "# Заголовок\n\n- item\n"
        let good = dir.appendingPathComponent("good.md")
        try Data(markdown.utf8).write(to: good)
        XCTAssertEqual(try MarkdownFileReader.read(good), markdown)

        // Non-UTF-8 bytes fail fast (QL then shows the system preview).
        let bad = dir.appendingPathComponent("bad.md")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: bad)
        XCTAssertThrowsError(try MarkdownFileReader.read(bad))

        // A missing file surfaces the underlying I/O error.
        let missing = dir.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try MarkdownFileReader.read(missing))
    }
}
