import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Comparing a document with an older version of itself.
@MainActor
final class CompareEngineTests: XCTestCase {
    private func merge(_ current: String, _ baseline: String) -> CompareEngine.Result {
        CompareEngine.merge(current: Array(current.utf8), baseline: Array(baseline.utf8))
    }

    private func text(_ result: CompareEngine.Result) -> String {
        String(decoding: result.bytes, as: UTF8.self)
    }

    /// The mark on the block a piece of text starts in.
    private func mark(_ result: CompareEngine.Result, containing needle: String)
        -> CompareEngine.Mark?
    {
        let haystack = text(result)
        guard let range = haystack.range(of: needle) else { return nil }
        return result.mark(
            atByte: haystack.utf8.distance(
                from: haystack.utf8.startIndex,
                to: range.lowerBound.samePosition(in: haystack.utf8)!
            ))
    }

    func testIdenticalVersionsHaveNothingToShow() {
        let result = merge("# Title\n\nBody.\n", "# Title\n\nBody.\n")
        XCTAssertFalse(result.hasChanges)
        XCTAssertEqual(text(result), "# Title\n\nBody.\n")
    }

    func testNewTextIsMarkedAsAdded() {
        let result = merge("# Title\n\nOld.\n\nNew.\n", "# Title\n\nOld.\n")
        XCTAssertEqual(mark(result, containing: "New."), .added)
        XCTAssertNil(mark(result, containing: "Old."))
    }

    func testDeletedTextComesBackMarkedAsRemoved() {
        let result = merge("# Title\n\nKept.\n", "# Title\n\nGone.\n\nKept.\n")
        XCTAssertTrue(text(result).contains("Gone."), "removed text is shown, not dropped")
        XCTAssertEqual(mark(result, containing: "Gone."), .removed)
    }

    func testAChangedParagraphReadsAsOldThenNew() {
        let result = merge("Answer is 43.\n", "Answer is 42.\n")
        XCTAssertEqual(text(result), "Answer is 42.\n\nAnswer is 43.\n")
        XCTAssertEqual(mark(result, containing: "42"), .removed)
        XCTAssertEqual(mark(result, containing: "43"), .added)
    }

    func testNeighbouringLinesBecomeOneMark() {
        let result = merge("a\nb\nc\n", "a\n")
        XCTAssertEqual(result.marks.count, 1, "two added lines are one change")
        XCTAssertEqual(result.marks[0].mark, .added)
    }

    func testAWholesaleRewriteIsRemovedThenAdded() {
        let result = merge("Entirely different text.\n", "Nothing in common here.\n")
        XCTAssertEqual(text(result), "Nothing in common here.\n\nEntirely different text.\n")
        XCTAssertEqual(result.marks.map(\.mark), [.removed, .added])
    }

    func testAnUnterminatedLastLineIsNotAChange() {
        // The baseline ends without a newline and the current file has one more
        // line. Only the new line is a change; the missing terminator is not.
        let result = merge("one\ntwo", "one")
        XCTAssertEqual(text(result), "one\n\ntwo\n")
        XCTAssertEqual(mark(result, containing: "two"), .added)
        XCTAssertNil(mark(result, containing: "one"))
    }

    func testTheOldAndNewTextOfAParagraphStayTwoBlocks() {
        // Without a blank line between them the parser would read the two lines
        // as one paragraph, and the whole thing would take the mark of its first
        // byte — the old text and the new text tinted as a single removal.
        let result = merge("Answer is 43.\n", "Answer is 42.\n")
        let layout = DocumentLayout(
            document: Document(bytes: result.bytes),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
        layout.comparison = result
        XCTAssertEqual(layout.blockCount, 2)
        XCTAssertEqual((0..<layout.blockCount).map { layout.mark(at: $0) }, [.removed, .added])
    }

    /// The layout is what the view asks, so the mark has to survive the trip
    /// through the parser and land on the right block.
    func testTheLayoutMarksTheBlockThatChanged() throws {
        let result = merge("# Title\n\nKept.\n\nAdded.\n", "# Title\n\nKept.\n")
        let layout = DocumentLayout(
            document: Document(bytes: result.bytes),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
        layout.comparison = result
        let marks = (0..<layout.blockCount).map { layout.mark(at: $0) }
        XCTAssertEqual(marks, [nil, nil, .added])
    }

    func testWithoutAComparisonNothingIsMarked() {
        let layout = DocumentLayout(
            document: Document(text: "# Title\n\nBody.\n"),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
        XCTAssertNil(layout.mark(at: 0))
    }
}
