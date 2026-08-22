import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// The numbers in the bottom bar, and the promises attached to them.
@MainActor
final class DocumentSummaryTests: XCTestCase {
    private let report = """
        # Migration report

        Prose about the plan.

        ## Backfill

        - [x] Read the old schema
        - [x] Write the mapping
        - [ ] Run it against staging

        TODO: decide what happens to rows with no owner.

        ## Verification

        - [x] Compare balances
        - [ ] Sign off with finance
        """

    private func count(_ text: String) async -> DocumentSummary.Result {
        let engine = DocumentSummary()
        return await withCheckedContinuation { continuation in
            var resumed = false
            engine.count(Document(text: text)) { result in
                guard result.counts.isComplete, !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
        }
    }

    func testTickedBoxesAreCounted() async {
        let result = await count(report)
        XCTAssertEqual(result.counts.tasks, 5)
        XCTAssertEqual(result.counts.tasksDone, 3)
    }

    func testEachSectionCarriesItsOwnCount() async {
        let result = await count(report)
        // Heading order: Migration report, Backfill, Verification.
        XCTAssertEqual(result.sections.count, 3)
        XCTAssertEqual(result.sections[0].tasks, 0)
        XCTAssertEqual(result.sections[1].done, 2)
        XCTAssertEqual(result.sections[1].tasks, 3)
        XCTAssertEqual(result.sections[2].done, 1)
        XCTAssertEqual(result.sections[2].tasks, 2)
    }

    func testOpenQuestionsAreMarkersAndNothingElse() async {
        let result = await count(report)
        XCTAssertEqual(result.counts.openQuestions, 1)
        // A question mark is punctuation, not a state.
        let questions = await count("Is this done? Who knows?")
        XCTAssertEqual(questions.counts.openQuestions, 0)
        // An unticked box is progress, counted as progress.
        let boxes = await count("- [ ] not done yet")
        XCTAssertEqual(boxes.counts.openQuestions, 0)
        XCTAssertEqual(boxes.counts.tasks, 1)
    }

    func testAMarkerInsideAWordIsNotAMarker() {
        XCTAssertEqual(DocumentSummary.markers(in: "TODOS are not TODO"), 1)
        XCTAssertEqual(DocumentSummary.markers(in: "todo: fix it"), 1)
        XCTAssertEqual(DocumentSummary.markers(in: "AUTODOWNLOAD"), 0)
    }

    func testADocumentWithNoBoxesReportsNone() async {
        let result = await count("# Notes\n\nJust prose, nothing to tick.")
        XCTAssertEqual(result.counts.tasks, 0)
        XCTAssertEqual(result.counts.tasksDone, 0)
    }

    func testReadingTimeIsWordsOverTheStatedRate() {
        var counts = DocumentSummary.Counts()
        counts.words = DocumentSummary.readingRate * 3
        XCTAssertEqual(counts.readingMinutes, 3)
        counts.words = 1
        XCTAssertEqual(counts.readingMinutes, 1)
        counts.words = 0
        XCTAssertNil(counts.readingMinutes)
    }
}
