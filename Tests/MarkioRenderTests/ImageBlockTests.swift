import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Pictures: when a paragraph becomes one, and what happens when it cannot.
@MainActor
final class ImageBlockTests: XCTestCase {
    /// The fixture directory, found relative to this file so the test does not
    /// depend on where it is run from.
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-fixtures")
    }

    private func layout(_ markdown: String, baseURL: URL?) -> (Document, DocumentLayout) {
        let document = Document(text: markdown)
        return (
            document,
            DocumentLayout(
                document: document,
                theme: Theme(isDark: false),
                columnWidth: 520,
                baseURL: baseURL
            )
        )
    }

    private func hasImage(_ box: BlockBox) -> Bool {
        box.decorations.contains { decoration in
            if case .image = decoration { return true }
            return false
        }
    }

    func testAParagraphThatIsOnlyAnImageBecomesTheImage() {
        let base = fixtures.appendingPathComponent("images.md")
        let (_, layout) = layout("![a gradient](sample.png)\n", baseURL: base)
        let box = layout.box(at: 0)
        XCTAssertNotNil(box)
        XCTAssertTrue(hasImage(box!), "the block should carry a decoded image")
        XCTAssertGreaterThan(box!.height, 40)
    }

    func testAMissingFileFallsBackToTheAltText() {
        let base = fixtures.appendingPathComponent("images.md")
        let (document, layout) = layout("![missing picture](nowhere.png)\n", baseURL: base)
        let box = layout.box(at: 0)
        XCTAssertNotNil(box)
        XCTAssertFalse(hasImage(box!))
        XCTAssertEqual(
            box?.plainText,
            BlockPlainText.text(document: document, leaf: document.leaves[0])
        )
    }

    func testAnImageInsideProseStaysInline() {
        let base = fixtures.appendingPathComponent("images.md")
        let (_, layout) = layout("Text with ![a gradient](sample.png) in it.\n", baseURL: base)
        let box = layout.box(at: 0)
        XCTAssertNotNil(box)
        XCTAssertFalse(hasImage(box!), "an image sharing a line is not a picture block")
    }

    func testWithoutADocumentLocationThereAreNoImages() {
        let (document, layout) = layout("![a gradient](sample.png)\n", baseURL: nil)
        let box = layout.box(at: 0)
        XCTAssertNotNil(box)
        XCTAssertFalse(hasImage(box!))
        XCTAssertEqual(
            box?.plainText,
            BlockPlainText.text(document: document, leaf: document.leaves[0])
        )
    }

    func testARemoteImageIsNotFetched() {
        let base = fixtures.appendingPathComponent("images.md")
        let (_, layout) = layout("![remote](https://example.com/a.png)\n", baseURL: base)
        let box = layout.box(at: 0)
        XCTAssertNotNil(box)
        XCTAssertFalse(hasImage(box!), "there is no network path, so nothing can be drawn")
    }

    func testTheDrawnImageMatchesTheParityRule() {
        let base = fixtures.appendingPathComponent("images.md")
        let (document, layout) = layout("![a gradient](sample.png)\n", baseURL: base)
        let box = layout.box(at: 0)
        // A picture has no characters of its own, so Find and Copy see the alt
        // text — the same text the fallback would have drawn.
        XCTAssertEqual(
            box?.plainText,
            BlockPlainText.text(document: document, leaf: document.leaves[0])
        )
    }
}
