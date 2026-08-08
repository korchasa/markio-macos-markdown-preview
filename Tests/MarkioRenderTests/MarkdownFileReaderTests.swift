import XCTest

@testable import MarkioRender

/// Reading a bounded slice of a file for a preview.
final class MarkdownFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio2-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, as name: String = "file.md") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testASmallFileComesBackWhole() throws {
        let url = try write("# Title\n\nBody.\n")
        XCTAssertEqual(
            String(decoding: try MarkdownFileReader.read(url, limit: 1024), as: UTF8.self),
            "# Title\n\nBody.\n"
        )
    }

    func testALongFileStopsAtTheLimit() throws {
        let url = try write(String(repeating: "a", count: 5000))
        XCTAssertEqual(try MarkdownFileReader.read(url, limit: 100).count, 100)
    }

    func testTheCutNeverLandsInsideACharacter() throws {
        // Every character here is two bytes, so an even limit splits one in half
        // unless the reader steps back.
        let url = try write(String(repeating: "я", count: 200))
        let bytes = try MarkdownFileReader.read(url, limit: 101)
        XCTAssertEqual(bytes.count, 100)
        let text = String(data: Data(bytes), encoding: .utf8)
        XCTAssertEqual(text?.count, 50, "the tail must decode as whole characters")
    }

    func testAnEmptyFileIsNotAnError() throws {
        XCTAssertEqual(try MarkdownFileReader.read(try write(""), limit: 1024), [])
    }

    func testAMissingFileThrows() {
        let missing = directory.appendingPathComponent("nowhere.md")
        XCTAssertThrowsError(try MarkdownFileReader.read(missing, limit: 1024))
    }
}
