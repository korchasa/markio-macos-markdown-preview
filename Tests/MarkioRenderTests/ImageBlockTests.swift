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

    /// A picture taller than it is wide fills the column as a wide one does.
    /// The decoder capped its height at the column's pixel width, so a tall
    /// side-by-side picture came out at two thirds of the column or less.
    func testATallImageIsAsWideAsTheColumn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-tall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tall.png")
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 1200, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 3000))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let (_, layout) = layout(
            "![tall](tall.png)\n", baseURL: folder.appendingPathComponent("doc.md"))
        let box = try XCTUnwrap(layout.box(at: 0))
        var drawn: CGRect?
        for case .image(_, let rect) in box.decorations { drawn = rect }
        XCTAssertEqual(try XCTUnwrap(drawn).width, 520, accuracy: 1)
    }

    /// No picture, and the text Find sees is the text that is drawn: the
    /// frame stands where the picture would.
    func testAMissingFileLeavesAnEmptyFrame() {
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

    func testAnImageInsideProseIsDrawnOnTheLine() throws {
        let base = fixtures.appendingPathComponent("images.md")
        let (_, layout) = layout("Text with ![a gradient](sample.png) in it.\n", baseURL: base)
        let box = try XCTUnwrap(layout.box(at: 0))
        XCTAssertTrue(hasImage(box), "a picture inside a sentence is drawn where it sits")
        // The picture replaces its own alt text, and only that: the prose
        // around it is untouched.
        XCTAssertEqual(box.plainText, "Text with \u{FFFC} in it.")
    }

    func testAMissingInlineImageKeepsItsPlaceInTheText() throws {
        let base = fixtures.appendingPathComponent("images.md")
        let (_, layout) = layout("Text with ![gone](nowhere.png) in it.\n", baseURL: base)
        let box = try XCTUnwrap(layout.box(at: 0))
        XCTAssertFalse(hasImage(box))
        // Whether the file was readable cannot change the text, or a match
        // offset from Find would land in the wrong place.
        XCTAssertEqual(box.plainText, "Text with \u{FFFC} in it.")
    }

    func testARemoteInlineImageKeepsItsAltText() throws {
        let base = fixtures.appendingPathComponent("images.md")
        let (_, layout) = layout("Text with ![a photo](https://e.com/a.png) here.\n", baseURL: base)
        let box = try XCTUnwrap(layout.box(at: 0))
        XCTAssertFalse(hasImage(box))
        XCTAssertEqual(box.plainText, "Text with 🖼 a photo here.")
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
