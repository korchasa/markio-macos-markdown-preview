import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Focus folds the document down to the section the reader is in.
///
/// It is the disclosure machinery pointed at headings instead of at `<details>`,
/// so the same line holds: nothing is dropped, the blocks are still there and
/// still searchable, they simply take no room. What is deliberately kept on
/// screen is every heading — folded, the document reads as its own table of
/// contents with one part open.
@MainActor
final class FocusTests: XCTestCase {
    private let markdown = """
        # Report

        Opening prose.

        ## First finding

        What the first finding was.

        Still the first finding.

        ## Second finding

        What the second finding was.

        ### A detail of the second

        The detail itself.

        ## Third finding

        What the third finding was.
        """

    private func makeLayout(_ text: String) -> DocumentLayout {
        DocumentLayout(
            document: Document(text: text),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
    }

    /// Ordinals in `markdown`: 0 `# Report`, 1 prose, 2 `## First finding`,
    /// 3 and 4 its paragraphs, 5 `## Second finding`, 6 its paragraph,
    /// 7 `### A detail`, 8 its paragraph, 9 `## Third finding`, 10 its
    /// paragraph.
    func testFoldingKeepsTheHeadingsAndTheChosenSection() {
        let layout = makeLayout(markdown)
        XCTAssertEqual(layout.blockCount, 11)

        layout.setFocus(5)

        XCTAssertEqual(layout.focusedHeading, 5)
        XCTAssertEqual(
            (0..<11).map { layout.isHidden($0) },
            [
                false,  // # Report
                true,  // opening prose
                false,  // ## First finding
                true, true,
                false,  // ## Second finding — the section in focus
                false,  // its paragraph
                false,  // ### A detail, nested under it
                false,  // the detail's paragraph
                false,  // ## Third finding
                true,
            ])
    }

    func testASubsectionBelongsToTheSectionAboveIt() {
        let layout = makeLayout(markdown)
        // Focusing the third finding must not keep the second's detail, which
        // sits between the two in the file.
        layout.setFocus(9)
        XCTAssertTrue(layout.isHidden(8))
        XCTAssertFalse(layout.isHidden(10))
    }

    func testAFoldedBlockTakesNoRoomAndGetsItBack() {
        let layout = makeLayout(markdown)
        let whole = layout.totalHeight

        layout.setFocus(5)
        XCTAssertEqual(layout.box(at: 3)?.height, 0)
        XCTAssertEqual(layout.height(of: 3), 0)
        XCTAssertLessThan(layout.totalHeight, whole)

        layout.setFocus(nil)
        XCTAssertNil(layout.focusedHeading)
        XCTAssertFalse(layout.isHidden(3))
        XCTAssertGreaterThan(layout.box(at: 3)?.height ?? 0, 0)
        XCTAssertEqual(layout.totalHeight, whole, accuracy: 0.5)
    }

    func testFocusingAParagraphFocusesTheHeadingItBelongsTo() {
        let layout = makeLayout(markdown)
        // The command takes the block at the top of the window, which is
        // usually prose rather than the heading itself.
        layout.setFocus(6)
        XCTAssertEqual(layout.focusedHeading, 5)
        XCTAssertFalse(layout.isHidden(6))
    }

    func testProseAboveTheFirstHeadingKeepsItself() {
        let layout = makeLayout("Just prose.\n\nAnd more of it.")
        layout.setFocus(1)
        XCTAssertEqual(layout.focusedHeading, 1)
        XCTAssertFalse(layout.isHidden(1))
        XCTAssertTrue(layout.isHidden(0))
    }

    func testFoldingAndAClosedSectionBothHold() {
        let layout = makeLayout(
            """
            # One

            <details>
            <summary>Closed</summary>

            Hidden prose.

            </details>

            # Two

            Second section.
            """)
        // 0 `# One`, 1 <details>, 2 hidden prose, 3 </details>, 4 `# Two`,
        // 5 its paragraph. Focus on the first section must not open what the
        // author left closed.
        layout.setFocus(0)
        XCTAssertTrue(layout.isHidden(2))
        XCTAssertFalse(layout.isHidden(1))
        XCTAssertTrue(layout.isHidden(5))
    }

    func testAReloadThatMovesTheHeadingDropsTheFocus() {
        let layout = makeLayout(markdown)
        layout.setFocus(5)
        layout.replace(document: Document(text: "Only prose now."))
        XCTAssertNil(layout.focusedHeading)
        XCTAssertFalse(layout.isHidden(0))
    }
}
