import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// A `<details>` section hides its contents until the reader asks for them.
///
/// The hiding is done in the layout, not in the parser: the blocks are still
/// there, still searchable, still part of the document — they simply take no
/// room. These tests hold that line, because the tempting shortcut — dropping
/// the blocks — would quietly break find and copy.
@MainActor
final class DisclosureTests: XCTestCase {
    private let markdown = """
        Before.

        <details>
        <summary>Closed by default</summary>

        Hidden prose.

        Another hidden paragraph.

        </details>

        After.
        """

    private func makeLayout(_ text: String) -> DocumentLayout {
        DocumentLayout(
            document: Document(text: text),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
    }

    func testAClosedSectionHidesItsContents() {
        let layout = makeLayout(markdown)
        // Before, <details>, two paragraphs, </details>, After.
        XCTAssertEqual(layout.blockCount, 6)
        XCTAssertEqual(
            (0..<6).map { layout.isHidden($0) },
            [
                false, false, true, true, true, false,
            ])
        for ordinal in 2...4 {
            XCTAssertEqual(layout.box(at: ordinal)?.height, 0, "ordinal \(ordinal)")
            XCTAssertEqual(layout.height(of: ordinal), 0, "ordinal \(ordinal)")
        }
    }

    func testOpeningASectionGivesItsBlocksTheirHeightBack() {
        let layout = makeLayout(markdown)
        let closedHeight = layout.totalHeight
        XCTAssertTrue(layout.toggleSection(at: 1))
        XCTAssertFalse(layout.isHidden(2))
        XCTAssertGreaterThan(layout.totalHeight, closedHeight)
        XCTAssertGreaterThan(layout.box(at: 2)?.height ?? 0, 0)

        XCTAssertTrue(layout.toggleSection(at: 1))
        XCTAssertTrue(layout.isHidden(2))
        XCTAssertEqual(layout.totalHeight, closedHeight, accuracy: 0.5)
    }

    func testClickingSomethingThatIsNotAHeaderChangesNothing() {
        let layout = makeLayout(markdown)
        XCTAssertFalse(layout.toggleSection(at: 0))
        XCTAssertFalse(layout.toggleSection(at: 5))
    }

    func testAnOpenSectionStartsOpen() {
        let layout = makeLayout(
            """
            <details open>
            <summary>Shown</summary>

            Visible prose.

            </details>
            """
        )
        XCTAssertFalse(layout.isHidden(1))
        XCTAssertEqual(layout.box(at: 0)?.disclosureRegion?.isExpanded, true)
    }

    func testASectionNobodyClosedRunsToTheEnd() {
        let layout = makeLayout(
            """
            <details>
            <summary>Unclosed</summary>

            One.

            Two.
            """
        )
        XCTAssertTrue(layout.isHidden(1))
        XCTAssertTrue(layout.isHidden(2))
    }

    func testTheHeaderTextIsTheSummary() {
        let layout = makeLayout(markdown)
        XCTAssertEqual(layout.box(at: 1)?.plainText, "Closed by default")
        XCTAssertEqual(
            BlockPlainText.text(document: layout.document, leaf: layout.document.leaves[1]),
            "Closed by default"
        )
    }
}
