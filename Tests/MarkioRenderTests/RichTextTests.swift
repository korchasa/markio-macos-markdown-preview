import AppKit
import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Copying a selection with its styles, and copying it plainly at the same
/// time: the rich flavour is an addition, never a replacement.
@MainActor
final class RichTextTests: XCTestCase {
    private func makeLayout(_ text: String) -> DocumentLayout {
        DocumentLayout(
            document: Document(text: text), theme: Theme(isDark: false), columnWidth: 520)
    }

    private func copied(_ text: String, ordinal: Int = 0) -> NSAttributedString {
        let layout = makeLayout(text)
        let box = layout.box(at: ordinal)!
        return RichText.attributed(box: box, from: 0, to: (box.plainText as NSString).length)
    }

    /// The whole promise of the plain flavour in one assertion.
    func testThePlainTextIsExactlyWhatItWasBefore() {
        let layout = makeLayout("Some **bold** and `code` and [a link](https://example.com).")
        let box = layout.box(at: 0)!
        XCTAssertEqual(
            RichText.attributed(box: box, from: 0, to: (box.plainText as NSString).length).string,
            box.plainText)
    }

    func testAPartOfABlockCopiesAsThatPart() {
        let layout = makeLayout("One two three")
        let box = layout.box(at: 0)!
        XCTAssertEqual(RichText.attributed(box: box, from: 4, to: 7).string, "two")
    }

    /// A table's tabs and newlines live between the segments, not inside them,
    /// so a copy that walked the segments alone would run the cells together.
    func testATableKeepsTheSeparatorsBetweenItsCells() {
        let layout = makeLayout(
            """
            | A | B |
            | --- | --- |
            | one | two |
            """)
        let box = layout.box(at: 0)!
        let copied = RichText.attributed(box: box, from: 0, to: (box.plainText as NSString).length)
        XCTAssertEqual(copied.string, box.plainText)
        XCTAssertTrue(copied.string.contains("one\ttwo"))
    }

    func testBoldTextKeepsItsWeightThroughTheTranslation() {
        let rich = RichText.appKit(copied("Some **bold** text"))
        let bold = (rich.string as NSString).range(of: "bold")
        let font = rich.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        let plain = rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(plain!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testAHeadingIsCopiedAtItsOwnSize() {
        let heading = RichText.appKit(copied("# A heading"))
        let body = RichText.appKit(copied("Just prose."))
        let headingFont = heading.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let bodyFont = body.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize)
    }

    func testALinkCarriesItsDestination() {
        let rich = RichText.appKit(copied("Read [the notes](https://example.com/notes) first."))
        let range = (rich.string as NSString).range(of: "the notes")
        XCTAssertEqual(
            rich.attribute(.link, at: range.location, effectiveRange: nil) as? String,
            "https://example.com/notes")
    }

    /// The picture of a link is not a link: alt text has no destination to go
    /// to, and offering one would invite a click that goes nowhere.
    func testAnImagesAltTextIsNotALink() {
        let rich = RichText.appKit(copied("![a picture](pic.png)"))
        for index in 0..<rich.length {
            XCTAssertNil(rich.attribute(.link, at: index, effectiveRange: nil))
        }
    }

    func testTheColourSurvivesAsAnAppKitColour() {
        let rich = RichText.appKit(copied("Just prose."))
        XCTAssertNotNil(rich.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        // And the CoreText key it came from is gone rather than carried along.
        XCTAssertNil(rich.attribute(AttributedBuilder.colorKey, at: 0, effectiveRange: nil))
    }

    func testTheRTFReadsBackAsTheSameText() throws {
        let rich = copied("Some **bold** and `code`.")
        let data = try XCTUnwrap(RichText.rtf(rich))
        let read = try XCTUnwrap(
            NSAttributedString(rtf: data, documentAttributes: nil))
        XCTAssertEqual(read.string, rich.string)
        let bold = (read.string as NSString).range(of: "bold")
        let font = read.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// A diagram has no text of its own, so what it pastes is what the document
    /// said — its source, which is step one of the plan for pictures.
    func testADiagramPastesAsItsSource() {
        let layout = makeLayout("```mermaid\ngraph TD;\n  A-->B;\n```")
        let box = layout.box(at: 0)!
        let copied = RichText.attributed(box: box, from: 0, to: (box.plainText as NSString).length)
        XCTAssertTrue(copied.string.contains("graph TD"))
    }
}
