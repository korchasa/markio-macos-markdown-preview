import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// A path in a report becomes a link only when the file is really there.
///
/// Two things are being held at once. One is the feature: an agent's report
/// names a file and a line, and a click goes there. The other is the safety
/// argument that makes it allowed at all — the document does not decide what
/// can be opened, the disk does, and the text itself is never rewritten, so
/// find and copy see the same characters they saw before the paths lit up.
@MainActor
final class CodePathLinkTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "let x = 1\n".write(
            to: folder.appendingPathComponent("Sources/Real.swift"), atomically: true,
            encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var document: URL { folder.appendingPathComponent("report.md") }

    private func linked(_ text: String) -> InlineContent {
        let bytes = Array(text.utf8)
        let parsed = InlineParser.parse(content: bytes, references: [:], documentBytes: [])
        return CodePathLinks.apply(to: parsed, bytes: bytes) {
            CodePathLinks.destination(for: $0, near: document)
        }
    }

    func testAPathThatExistsBecomesALink() {
        let content = linked("I changed Sources/Real.swift:12 today")
        XCTAssertEqual(content.links.map(\.destination), ["Sources/Real.swift:12"])
        let link = content.runs.first { $0.link >= 0 }
        XCTAssertNotNil(link)
        XCTAssertTrue(link?.style.contains(.link) ?? false)
    }

    func testAPathThatDoesNotExistStaysText() {
        let content = linked("I changed Sources/Invented.swift:12 today")
        XCTAssertTrue(content.links.isEmpty)
        XCTAssertFalse(content.runs.contains { $0.link >= 0 })
    }

    func testTheTextIsUnchangedSoFindAndCopyAgree() {
        let text = "I changed Sources/Real.swift:12 today"
        let bytes = Array(text.utf8)
        let before = InlineText.plain(
            InlineParser.parse(content: bytes, references: [:], documentBytes: []), bytes: bytes)
        let after = InlineText.plain(linked(text), bytes: bytes)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after, text)
    }

    func testAPathInsideACodeSpanIsStillOffered() {
        // This is the shape an agent actually writes.
        let content = linked("see `Sources/Real.swift` for it")
        XCTAssertEqual(content.links.map(\.destination), ["Sources/Real.swift"])
    }

    func testAPathClimbingOutOfTheFolderIsRefused() {
        XCTAssertNil(
            CodePathLinks.destination(
                for: CodePath.Candidate(range: ByteRange(0, 0), path: "../secret.swift", line: nil),
                near: document))
    }

    func testADirectoryIsNotAFileToOpen() {
        XCTAssertNil(
            CodePathLinks.destination(
                for: CodePath.Candidate(range: ByteRange(0, 0), path: "Sources", line: nil),
                near: document))
    }

    func testALinkLabelIsLeftAlone() {
        // The path is already the label of a real link; a second link inside it
        // would fight with the first for the click.
        let content = linked("[Sources/Real.swift](https://example.com)")
        XCTAssertEqual(content.links.map(\.destination), ["https://example.com"])
    }
}
