import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Where a document breaks into slides, and when it is not a deck at all.
final class SlidesTests: XCTestCase {
    func testThematicBreaksWinWhenTheAuthorWroteThem() {
        let document = Document(
            text: """
                First slide.

                ---

                Second slide.

                ---

                Third slide.
                """)
        XCTAssertEqual(Slides.split(document).count, 3)
    }

    func testTheBreakItselfIsNotDrawnOnASlide() {
        let document = Document(text: "One.\n\n---\n\nTwo.")
        let slides = Slides.split(document)
        // 0 paragraph, 1 the rule, 2 paragraph.
        XCTAssertEqual(slides, [0..<1, 2..<3])
    }

    func testATitleAndItsSectionsMakeADeckOfTheSections() {
        let document = Document(
            text: """
                # Report

                Opening.

                ## One

                First.

                ## Two

                Second.
                """)
        // The title and its prose are the first slide; each section follows.
        XCTAssertEqual(Slides.split(document).count, 3)
    }

    func testADocumentWithNothingToSplitOnIsNotADeck() {
        XCTAssertTrue(Slides.split(Document(text: "Just prose.\n\nAnd more.")).isEmpty)
        XCTAssertTrue(Slides.split(Document(text: "# Only one heading\n\nText.")).isEmpty)
        XCTAssertTrue(Slides.split(Document(text: "")).isEmpty)
    }

    func testEverySlideHoldsBlocksAndTheyDoNotOverlap() {
        let document = Document(
            text: """
                # A

                one

                ## B

                two

                ## C

                three
                """)
        let slides = Slides.split(document)
        XCTAssertFalse(slides.contains { $0.isEmpty })
        for (previous, next) in zip(slides, slides.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.upperBound, next.lowerBound)
        }
    }
}
