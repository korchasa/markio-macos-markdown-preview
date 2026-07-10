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
