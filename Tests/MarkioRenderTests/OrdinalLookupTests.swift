import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Mapping a block back to its position in reading order.
///
/// The outline does this once per heading while the first window is being
/// built. It was a linear scan, and on a 32 MB document — six figures of
/// headings among six figures of leaves — that quadratic pair cost 39 seconds
/// before anything appeared on screen. The timing test below is the guard: it
/// is not measuring speed for its own sake, it is refusing a scan.
@MainActor
final class OrdinalLookupTests: XCTestCase {
    private func manyBlocks(_ count: Int) -> Document {
        var text = ""
        for i in 0..<count {
            text += "## Heading \(i)\n\nParagraph \(i).\n\n"
        }
        return Document(text: text)
    }

    private func makeLayout(_ document: Document) -> DocumentLayout {
        DocumentLayout(document: document, theme: Theme(isDark: false), columnWidth: 420)
    }

    func testEveryLeafMapsToItsOwnOrdinal() {
        let document = manyBlocks(500)
        let layout = makeLayout(document)
        for (ordinal, leaf) in document.leaves.enumerated() {
            XCTAssertEqual(layout.ordinal(ofLeaf: leaf), ordinal)
        }
    }

    func testABlockThatIsNotALeafHasNoOrdinal() {
        let document = Document(text: "> quoted\n\n- item\n")
        let layout = makeLayout(document)
        // Block 0 is the document itself: a container, never a layout unit.
        XCTAssertNil(layout.ordinal(ofLeaf: 0))
        XCTAssertNil(layout.ordinal(ofLeaf: Int32(document.blocks.count + 10)))
    }

    func testLookingUpEveryLeafIsNotQuadratic() {
        let document = manyBlocks(20_000)
        let layout = makeLayout(document)
        XCTAssertGreaterThan(document.leaves.count, 30_000)

        let started = ProcessInfo.processInfo.systemUptime
        for leaf in document.leaves {
            XCTAssertNotNil(layout.ordinal(ofLeaf: leaf))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        // Binary search does this in milliseconds even in a debug build; a scan
        // over 40 000 leaves is three orders of magnitude slower.
        XCTAssertLessThan(elapsed, 3.0, "leaf lookup is scanning, not searching")
    }
}
