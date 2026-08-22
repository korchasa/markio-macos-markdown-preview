import MarkioRender
import XCTest

@testable import Markio

/// What the bottom bar says, given what was counted.
@MainActor
final class SummaryBarTests: XCTestCase {
    private func counts(
        tasks: Int = 0, done: Int = 0, words: Int = 0, open: Int = 0, progress: Double = 1
    ) -> DocumentSummary.Counts {
        var counts = DocumentSummary.Counts()
        counts.tasks = tasks
        counts.tasksDone = done
        counts.words = words
        counts.openQuestions = open
        counts.progress = progress
        return counts
    }

    func testADocumentWithNothingToReportSaysNothing() {
        XCTAssertEqual(DocumentWindowController.summary(counts()), "")
    }

    func testProgressComesFirstBecauseItIsWhatIsAskedFirst() {
        XCTAssertEqual(
            DocumentWindowController.summary(counts(tasks: 5, done: 3, words: 220, open: 1)),
            "3 of 5 done · 1 min at 220 wpm · 1 open")
    }

    func testADocumentWithNoBoxesShowsNoProgress() {
        // Not "0 of 0": the summary is a fact about the document, not a widget
        // that has to be filled.
        XCTAssertEqual(DocumentWindowController.summary(counts(words: 440)), "2 min at 220 wpm")
    }

    func testACountStillRunningSaysSo() {
        XCTAssertEqual(
            DocumentWindowController.summary(counts(words: 220, progress: 0.4)),
            "1 min at 220 wpm …")
    }
}
