import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// What the view needs in order to put a language badge and a Copy pill on a
/// fenced block: the block has to say where it is and what it is.
@MainActor
final class CodeRegionTests: XCTestCase {
    private func layout(_ markdown: String) -> DocumentLayout {
        DocumentLayout(
            document: Document(text: markdown),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
    }

    func testAFencedBlockCarriesItsLanguageAndItsFrame() throws {
        let box = try XCTUnwrap(layout("```swift\nlet answer = 42\n```\n").box(at: 0))
        let region = try XCTUnwrap(box.codeRegion)
        XCTAssertEqual(region.language, "swift")
        // The frame is the drawn box, so the controls land on the tinted
        // rectangle rather than beside it.
        XCTAssertGreaterThan(region.rect.width, 300)
        XCTAssertGreaterThan(region.rect.height, 20)
        XCTAssertLessThanOrEqual(region.rect.maxY, box.height)
    }

    func testAFenceWithoutALanguageStillOffersCopy() throws {
        let box = try XCTUnwrap(layout("```\nplain output\n```\n").box(at: 0))
        let region = try XCTUnwrap(box.codeRegion)
        XCTAssertEqual(region.language, "")
    }

    func testProseHasNoCodeRegion() throws {
        let box = try XCTUnwrap(layout("Just a sentence with `inline code` in it.\n").box(at: 0))
        XCTAssertNil(box.codeRegion)
    }

    func testCopyingAnAnsiBlockYieldsTextWithoutEscapes() throws {
        // Copy writes `plainText`, so the clipboard has to hold what the reader
        // sees — not the escape bytes that produced the colours.
        let escape = "\u{1B}"
        let box = try XCTUnwrap(layout("```\n\(escape)[32mok\(escape)[0m done\n```\n").box(at: 0))
        XCTAssertNotNil(box.codeRegion)
        XCTAssertEqual(box.plainText.trimmingCharacters(in: .newlines), "ok done")
    }
}
