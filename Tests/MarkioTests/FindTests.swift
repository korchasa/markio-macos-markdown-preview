import XCTest

@testable import Markio

/// Exercises the in-page find pipeline (`search`/`findNext`/`findPrev`/
/// `clearSearch`) over rendered content. [REF:fr:find] [REF:sds:find-bar]
@MainActor
final class FindTests: XCTestCase {
    func testFindsAllMatchesAndCycles() async throws {
        let preview = try await makeLoadedPreview()
        await preview.render("alpha beta alpha gamma Alpha")

        // Case-insensitive: "alpha" matches alpha, alpha, Alpha → 3.
        let result = await preview.search("alpha")
        XCTAssertEqual(result.count, 3, "case-insensitive match count")
        XCTAssertEqual(result.current, 1, "first match is current after a fresh search")

        let marks = try await count(
            preview, "document.querySelectorAll('#content mark.markio-find').length")
        XCTAssertEqual(marks, 3, "each match wrapped in a <mark>")

        let currents = try await count(
            preview, "document.querySelectorAll('#content mark.markio-find-current').length")
        XCTAssertEqual(currents, 1, "exactly one current match emphasized")

        // Forward cycling wraps around.
        let second = await preview.findNext()
        XCTAssertEqual(second, FindResult(count: 3, current: 2))
        let third = await preview.findNext()
        XCTAssertEqual(third, FindResult(count: 3, current: 3))
        let wrapped = await preview.findNext()
        XCTAssertEqual(wrapped, FindResult(count: 3, current: 1), "wraps to first")
        // Backward from the first wraps to the last.
        let back = await preview.findPrev()
        XCTAssertEqual(back, FindResult(count: 3, current: 3), "wraps to last")

        // Clearing removes every highlight and leaves the text intact.
        await preview.clearSearch()
        let cleared = try await count(
            preview, "document.querySelectorAll('#content mark.markio-find').length")
        XCTAssertEqual(cleared, 0, "clearSearch unwraps all marks")
        let text = try await preview.evaluate("document.getElementById('content').textContent")
        XCTAssertEqual(
            (text as? String)?.contains("alpha beta alpha gamma Alpha"), true,
            "clearing restores the original text")
    }

    // [REF:fr:find] — "N of M" counter formatting shown in the find HUD.
    func testCounterText() {
        XCTAssertEqual(FindResult(count: 17, current: 3).counterText, "3 of 17")
        XCTAssertEqual(FindResult.empty.counterText, "0 of 0")
    }

    /// A query spanning syntax-highlight token spans matches inside fenced
    /// code, matches span inline formatting in table cells, and a match never
    /// crosses a block boundary. [REF:fr:find]
    func testFindsAcrossTokenSpansInCodeAndTables() async throws {
        let preview = try await makeLoadedPreview()
        await preview.render(
            """
            First para ends here.

            Second para starts.

            ```js
            const value = 1;
            ```

            | Head |
            | --- |
            | alpha *beta* gamma |
            """)

        // highlight.js wraps `const` in a token <span>, so this match crosses
        // a text-node boundary inside the code block.
        let code = await preview.search("const value")
        XCTAssertEqual(code.count, 1, "match spanning highlight token spans is found")
        let codeMarks = try await count(
            preview,
            "document.querySelectorAll('#content pre code mark.markio-find').length")
        XCTAssertGreaterThanOrEqual(codeMarks, 2, "cross-span match is split into segments")
        let currents = try await count(
            preview,
            "document.querySelectorAll('#content mark.markio-find-current').length")
        XCTAssertEqual(currents, codeMarks, "every segment of the current match is emphasized")

        // Match spanning <em> inside a table cell: alpha + beta + gamma.
        let cell = await preview.search("alpha beta gamma")
        XCTAssertEqual(cell.count, 1, "match spanning inline formatting in a table cell")
        let cellMarks = try await count(
            preview,
            "document.querySelectorAll('#content td mark.markio-find').length")
        XCTAssertGreaterThanOrEqual(cellMarks, 3, "segments in the cell around the <em>")

        // Text flowing across a paragraph boundary is NOT one match.
        let crossBlock = await preview.search("here. Second")
        XCTAssertEqual(crossBlock.count, 0, "a match never spans a block boundary")

        // Clearing restores the exact original text of the code block.
        await preview.clearSearch()
        let codeText = try await preview.evaluate(
            "document.querySelector('#content pre code').textContent")
        XCTAssertEqual(
            (codeText as? String)?.contains("const value = 1;"), true,
            "clearSearch restores split code text nodes")
    }

    /// The overview strip shows one tick per match, the current tick tracks
    /// findNext, re-renders never duplicate the strip, and clearing removes
    /// it. [REF:fr:find]
    func testMinimapTicksFollowMatches() async throws {
        let preview = try await makeLoadedPreview()
        await preview.render("alpha beta alpha")

        _ = await preview.search("alpha")
        let strips = try await count(
            preview, "document.querySelectorAll('#markio-find-minimap').length")
        XCTAssertEqual(strips, 1, "one overview strip while a search is active")
        let ticks = try await count(
            preview,
            "document.querySelectorAll('#markio-find-minimap .markio-find-tick').length")
        XCTAssertEqual(ticks, 2, "one tick per match")

        let currentIndexJS =
            "Array.prototype.indexOf.call("
            + "document.querySelectorAll('#markio-find-minimap .markio-find-tick'), "
            + "document.querySelector('#markio-find-minimap .markio-find-tick-current'))"
        let first = try await count(preview, currentIndexJS)
        XCTAssertEqual(first, 0, "the first match's tick is current after a fresh search")
        _ = await preview.findNext()
        let second = try await count(preview, currentIndexJS)
        XCTAssertEqual(second, 1, "the current tick follows findNext")

        // A re-render plus re-search never stacks a second strip.
        await preview.render("alpha beta alpha")
        _ = await preview.search("alpha")
        let stripsAfterRerender = try await count(
            preview, "document.querySelectorAll('#markio-find-minimap').length")
        XCTAssertEqual(stripsAfterRerender, 1, "exactly one strip after re-render + re-search")

        await preview.clearSearch()
        let stripsAfterClear = try await count(
            preview, "document.querySelectorAll('#markio-find-minimap').length")
        XCTAssertEqual(stripsAfterClear, 0, "clearSearch removes the strip")
    }

    func testNoMatchReturnsEmpty() async throws {
        let preview = try await makeLoadedPreview()
        await preview.render("just some words")

        let none = await preview.search("zzz")
        XCTAssertEqual(none, .empty, "no match → empty result")
        let marks = try await count(
            preview, "document.querySelectorAll('#content mark.markio-find').length")
        XCTAssertEqual(marks, 0, "no match → no highlights")
    }
}
