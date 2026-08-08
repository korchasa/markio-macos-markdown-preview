import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// The two promises that make a large document cheap: memory does not grow as
/// the reader scrolls, and measuring a block above the viewport does not move
/// the text under their eyes.
@MainActor
final class DocumentLayoutTests: XCTestCase {
    private func longDocument(paragraphs: Int) -> Document {
        var text = ""
        for i in 0..<paragraphs {
            text += "## Section \(i)\n\nSome prose in section \(i), long enough to wrap "
            text += "across more than one line at the width this test uses.\n\n"
        }
        return Document(text: text)
    }

    private func makeLayout(_ document: Document) -> DocumentLayout {
        DocumentLayout(document: document, theme: Theme(isDark: false), columnWidth: 420)
    }

    func testScrollingDoesNotAccumulateBoxes() {
        let document = longDocument(paragraphs: 400)
        let layout = makeLayout(document)
        XCTAssertEqual(layout.residentLayoutBytes, 0)

        layout.prepare(range: 0..<20, anchor: 0)
        let atStart = layout.residentLayoutBytes
        XCTAssertGreaterThan(atStart, 0)

        // Walk the whole document a screenful at a time. Without eviction this
        // ends up holding every block; the point is that it does not.
        var ordinal = 0
        while ordinal + 20 < layout.blockCount {
            layout.prepare(range: ordinal..<(ordinal + 20), anchor: ordinal)
            ordinal += 20
        }
        XCTAssertLessThan(layout.residentLayoutBytes, atStart * 12)
    }

    func testMeasuringAboveTheAnchorReportsTheShift() {
        let document = longDocument(paragraphs: 200)
        let layout = makeLayout(document)

        // Jump straight to the middle: everything above is still an estimate.
        let anchor = layout.blockCount / 2
        let before = layout.offset(of: anchor)
        let shift = layout.prepare(range: 0..<10, anchor: anchor)
        let after = layout.offset(of: anchor)

        XCTAssertEqual(after - before, shift, accuracy: 0.001)
        XCTAssertNotEqual(shift, 0, "estimates should differ from measurements somewhere")
    }

    func testHeightsAreMeasuredOnlyWhereAsked() {
        let document = longDocument(paragraphs: 100)
        let layout = makeLayout(document)
        layout.prepare(range: 0..<5, anchor: 0)

        XCTAssertNotNil(layout.box(at: 3))
        XCTAssertGreaterThan(layout.height(of: 3), 0)
        // A block far away still has a height — an estimate — so the scrollbar
        // is right from the first frame.
        XCTAssertGreaterThan(layout.height(of: layout.blockCount - 1), 0)
    }

    func testEmptyDocumentHasAUsableHeight() {
        let layout = makeLayout(Document(text: ""))
        XCTAssertEqual(layout.blockCount, 0)
        XCTAssertGreaterThan(layout.totalHeight, 0)
        XCTAssertNil(layout.box(at: 0))
    }
}
