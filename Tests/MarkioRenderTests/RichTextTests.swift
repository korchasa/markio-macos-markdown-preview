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

    /// Part of a diagram is not a picture, so it stays the text it is — which
    /// was the whole of what step one could do.
    func testPartOfADiagramPastesAsItsSource() {
        let layout = makeLayout("```mermaid\nflowchart TD\n  A --> B\n```")
        let box = layout.box(at: 0)!
        let copied = RichText.attributed(box: box, from: 0, to: (box.plainText as NSString).length)
        XCTAssertTrue(copied.string.contains("flowchart TD"))
    }

    // MARK: - Step two: a table as a table, a diagram as a picture

    private func table(_ text: String) -> NSAttributedString? {
        RichText.table(box: makeLayout(text).box(at: 0)!)
    }

    /// The cells stay text and the grid stays a grid — which is the whole point
    /// of an `NSTextTable` over a picture of one.
    func testATableCopiesAsATable() throws {
        let copied = try XCTUnwrap(
            table(
                """
                | A | B |
                | --- | --- |
                | one | two |
                """))
        let style = try XCTUnwrap(
            copied.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 2)
        XCTAssertTrue(copied.string.contains("one"))
        XCTAssertTrue(copied.string.contains("two"))
    }

    /// Every cell has to name its own square, or the table rebuilds itself with
    /// its rows in a heap.
    func testEveryCellKnowsWhereItSits() throws {
        let copied = try XCTUnwrap(
            table(
                """
                | A | B |
                | --- | --- |
                | one | two |
                """))
        var seen: [(Int, Int)] = []
        copied.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: copied.length)
        ) { value, _, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
            else { return }
            seen.append((block.startingRow, block.startingColumn))
        }
        XCTAssertEqual(seen.map { "\($0.0),\($0.1)" }, ["0,0", "0,1", "1,0", "1,1"])
    }

    /// A column told to centre itself is centred in the paste too. The drawing
    /// applies the alignment as it lays each cell out, so it is not in the
    /// cell's text and had to be carried across on its own.
    func testAColumnKeepsItsAlignment() throws {
        let copied = try XCTUnwrap(
            table(
                """
                | A | B |
                | --- | :-: |
                | one | two |
                """))
        let two = (copied.string as NSString).range(of: "two")
        let style = try XCTUnwrap(
            copied.attribute(.paragraphStyle, at: two.location, effectiveRange: nil)
                as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .center)
        let one = (copied.string as NSString).range(of: "one")
        let left = try XCTUnwrap(
            copied.attribute(.paragraphStyle, at: one.location, effectiveRange: nil)
                as? NSParagraphStyle)
        XCTAssertEqual(left.alignment, .left)
    }

    /// A merged cell is why HTML tables are here at all, so it has to survive
    /// the copy as the merged cell it is.
    func testAMergedCellKeepsItsSpan() throws {
        let copied = try XCTUnwrap(
            table(
                """
                <table>
                <tr><th colspan="2">Both</th></tr>
                <tr><td>one</td><td>two</td></tr>
                </table>
                """))
        let first = try XCTUnwrap(
            (copied.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(first.columnSpan, 2)
    }

    /// The filter row is drawn by the viewer, not written by the author, and a
    /// copy that carried it would paste a word nobody typed.
    func testTheFilterRowIsNotCopied() throws {
        let rows = (1...6).map { "| row \($0) | \($0) |" }.joined(separator: "\n")
        let copied = try XCTUnwrap(
            table(
                """
                | A | B |
                | --- | --- |
                \(rows)
                """))
        XCTAssertFalse(copied.string.contains("Filter"))
    }

    /// Half a table is not a table: three cells of five have no honest grid, so
    /// the selection keeps the text it had.
    func testPartOfATableStaysText() {
        let layout = makeLayout(
            """
            | A | B |
            | --- | --- |
            | one | two |
            """)
        let box = layout.box(at: 0)!
        let piece = RichText.block(box: box, from: 0, to: 3, theme: layout.theme)
        XCTAssertNil(piece.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(piece.string, (box.plainText as NSString).substring(to: 3))
    }

    /// The picture, at last — and only RTFD can carry it.
    func testADiagramCopiesAsAPicture() throws {
        let layout = makeLayout("```mermaid\nflowchart TD\n  A --> B\n```")
        let box = layout.box(at: 0)!
        let picture = RichText.block(
            box: box, from: 0, to: (box.plainText as NSString).length, theme: layout.theme)
        let attachment = try XCTUnwrap(
            picture.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertNotNil(attachment.fileWrapper?.regularFileContents)
        // And it is still a picture after the trip through RTFD, which is the
        // only flavour on the pasteboard that can carry one.
        let data = try XCTUnwrap(RichText.rtfd(picture))
        let read = try XCTUnwrap(
            NSAttributedString(rtfd: data, documentAttributes: nil))
        XCTAssertNotNil(
            read.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        // Text alone has nothing to carry, so it gets no RTFD flavour at all.
        XCTAssertNil(RichText.rtfd(copied("Just prose.")))
    }

    // MARK: - What actually lands on the pasteboard

    /// The whole path, from a selection in a view to the flavours an
    /// application chooses between — on a pasteboard of the test's own, so the
    /// suite never touches the clipboard of whoever is running it.
    private func pasted(_ text: String) -> NSPasteboard {
        let layout = makeLayout(text)
        let view = DocumentView(layout: layout)
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.markio.tests.copy"))
        view.selectAll()
        view.copy(nil as Any?)
        return view.pasteboard
    }

    func testTheRichFlavoursReachThePasteboard() throws {
        let board = pasted(
            """
            | A | B |
            | --- | --- |
            | one | two |

            ```mermaid
            flowchart TD
              A --> B
            ```
            """)
        let types = board.types ?? []
        // Richest first: that is the order an application picks from.
        XCTAssertEqual(
            types.filter { [.rtfd, .rtf, .string].contains($0) }, [.rtfd, .rtf, .string])
        let read = try XCTUnwrap(
            NSAttributedString(
                rtfd: try XCTUnwrap(board.data(forType: .rtfd)),
                documentAttributes: nil))
        var hasTable = false
        var hasPicture = false
        read.enumerateAttributes(in: NSRange(location: 0, length: read.length)) { attrs, _, _ in
            if (attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock {
                hasTable = true
            }
            if attrs[.attachment] is NSTextAttachment { hasPicture = true }
        }
        XCTAssertTrue(hasTable)
        XCTAssertTrue(hasPicture)
    }

    /// The promise the whole feature is built on: whatever the rich flavours
    /// say, the plain one is character for character what it always was.
    func testThePlainFlavourIsUntouched() throws {
        let markdown = """
            | A | B |
            | --- | --- |
            | one | two |
            """
        let board = pasted(markdown)
        let layout = makeLayout(markdown)
        let view = DocumentView(layout: layout)
        view.selectAll()
        XCTAssertEqual(board.string(forType: .string), view.selectedText)
    }

    /// The RTF a table becomes has to read back as a table, or the flavour on
    /// the pasteboard is only a rumour of one.
    func testTheTableSurvivesTheRTFRoundTrip() throws {
        let copied = try XCTUnwrap(
            table(
                """
                | A | B |
                | --- | --- |
                | one | two |
                """))
        let data = try XCTUnwrap(RichText.rtf(copied))
        let read = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        let style = try XCTUnwrap(
            read.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(style.textBlocks.first is NSTextTableBlock)
    }
}
