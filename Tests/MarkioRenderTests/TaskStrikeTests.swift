import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// A ticked box reads as finished: its text is struck through where it is
/// drawn, and only there — plain text and an open box are untouched.
@MainActor
final class TaskStrikeTests: XCTestCase {
    private func boxes(_ text: String) -> [BlockBox] {
        let layout = DocumentLayout(
            document: Document(text: text), theme: Theme(isDark: false), columnWidth: 420)
        layout.prepare(range: 0..<layout.blockCount, anchor: 0)
        return (0..<layout.blockCount).compactMap { layout.box(at: $0) }
    }

    private func isStruck(_ box: BlockBox) -> Bool {
        guard let segment = box.segments.first, segment.attributed.length > 0 else { return false }
        let attributes = segment.attributed.attributes(at: 0, effectiveRange: nil)
        return attributes[.strikethroughStyle] != nil
    }

    func testATickedBoxStrikesItsText() {
        let boxes = boxes("- [x] Done\n- [ ] Open\n")
        let texts = boxes.map(\.plainText)
        XCTAssertEqual(texts, ["Done", "Open"])
        XCTAssertTrue(isStruck(boxes[0]))
        XCTAssertFalse(isStruck(boxes[1]))
    }
}

/// The open box the stepper led to is marked the way find's current match is,
/// so the reader can see which line the count just took them to.
@MainActor
final class CurrentTaskHighlightTests: XCTestCase {
    private func view(_ text: String) -> DocumentView {
        let layout = DocumentLayout(
            document: Document(text: text), theme: Theme(isDark: false), columnWidth: 420)
        let view = DocumentView(layout: layout)
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        scrollView.documentView = view
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        scrollView.layoutSubtreeIfNeeded()
        view.viewWillDraw()
        return view
    }

    func testTheCurrentOpenTaskIsHighlighted() throws {
        let view = view("- [ ] First\n- [ ] Second\n")
        let first = try XCTUnwrap(view.layout.box(at: 0))
        let second = try XCTUnwrap(view.layout.box(at: 1))
        XCTAssertTrue(view.highlights(box: second, ordinal: 1, selection: nil).isEmpty)

        view.setCurrentTask(ordinal: 1)
        XCTAssertTrue(view.highlights(box: first, ordinal: 0, selection: nil).isEmpty)
        let marked = view.highlights(box: second, ordinal: 1, selection: nil)
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked[0].color, view.layout.theme.palette.findCurrentMatch)
        XCTAssertFalse(marked[0].rects.isEmpty)

        view.setCurrentTask(ordinal: nil)
        XCTAssertTrue(view.highlights(box: second, ordinal: 1, selection: nil).isEmpty)
    }
}
