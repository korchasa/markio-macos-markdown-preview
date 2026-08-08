import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Find reports matches in reading order, streams them, and drops the results
/// of a query the reader has already replaced.
@MainActor
final class FindEngineTests: XCTestCase {
    private let sample = """
        # Needle in the heading

        A paragraph mentioning needle twice: needle.

        - A bullet with NEEDLE in capitals
        - A bullet with nothing

        ```swift
        let needle = 1
        ```
        """

    /// Run a search to completion and return every match reported.
    private func search(_ query: String, in text: String) -> [DocumentView.FindMatch] {
        let document = Document(text: text)
        let engine = FindEngine()
        let finished = expectation(description: "search completes")
        var latest: [DocumentView.FindMatch] = []
        engine.search(query, in: document) { result in
            latest = result.matches
            if result.isComplete { finished.fulfill() }
        }
        wait(for: [finished], timeout: 5)
        return latest
    }

    func testMatchesAreFoundInReadingOrder() {
        let matches = search("needle", in: sample)
        XCTAssertEqual(matches.count, 5, "heading, two in the paragraph, the bullet, the code")
        for (previous, next) in zip(matches, matches.dropFirst()) {
            XCTAssertTrue(
                previous.ordinal < next.ordinal
                    || (previous.ordinal == next.ordinal && previous.location < next.location),
                "matches out of order at ordinal \(next.ordinal)"
            )
        }
    }

    func testSearchIgnoresCase() {
        XCTAssertEqual(search("NEEDLE", in: sample).count, search("needle", in: sample).count)
    }

    func testMatchesLandOnTheBlockText() {
        let document = Document(text: sample)
        let matches = search("needle", in: sample)
        for match in matches {
            let text =
                BlockPlainText.text(document: document, leaf: document.leaves[match.ordinal])
                as NSString
            XCTAssertLessThanOrEqual(match.location + match.length, text.length)
            XCTAssertEqual(
                text.substring(with: NSRange(location: match.location, length: match.length))
                    .lowercased(),
                "needle"
            )
        }
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(search("", in: sample).isEmpty)
    }

    func testMissingQueryFindsNothing() {
        XCTAssertTrue(search("haystack", in: sample).isEmpty)
    }
}
