import XCTest

@testable import MarkdownKit

/// What counts as a path in prose, and — more important — what does not.
///
/// Recognition is deliberately generous here and filtered by the disk later,
/// but generous is not the same as careless: a date, a version number, a URL
/// and a sentence with a full stop in it all have to come back empty, because
/// every false positive is a word in the reader's document that turns blue and
/// invites a click.
final class CodePathTests: XCTestCase {
    private func paths(_ text: String) -> [String] {
        CodePath.candidates(in: Array(text.utf8)).map(\.path)
    }

    private func lines(_ text: String) -> [Int?] {
        CodePath.candidates(in: Array(text.utf8)).map(\.line)
    }

    func testAPathWithALineNumberIsFound() {
        XCTAssertEqual(
            paths("see Sources/MarkioRender/Mermaid.swift:214 for the layout"),
            ["Sources/MarkioRender/Mermaid.swift"])
        XCTAssertEqual(
            lines("see Sources/MarkioRender/Mermaid.swift:214 for the layout"), [214])
    }

    func testABareFileNameNeedsAKnownExtension() {
        XCTAssertEqual(paths("open deno.json and read it"), ["deno.json"])
        XCTAssertEqual(paths("the app is fine"), [])
    }

    func testADirectoryIsEnoughOnItsOwn() {
        // No extension at all, but a separator says it is a path.
        XCTAssertEqual(paths("under Sources/MarkioRender/AGENTS"), ["Sources/MarkioRender/AGENTS"])
    }

    func testADateIsNotAPath() {
        XCTAssertEqual(paths("on 2026-08-13 the build went out"), [])
        XCTAssertEqual(paths("version 1.2.3 shipped"), [])
        XCTAssertEqual(paths("at 09:30 exactly"), [])
    }

    func testAURLIsNotAPath() {
        XCTAssertEqual(paths("https://example.com/a/b.swift is a page"), [])
        XCTAssertEqual(paths("markio.korchasa.dev/privacy"), ["markio.korchasa.dev/privacy"])
    }

    func testAnAbsolutePathIsNeverOffered() {
        XCTAssertEqual(paths("/etc/passwd holds nothing"), [])
        XCTAssertEqual(paths("~/Library/Preferences/x.plist"), [])
    }

    func testPunctuationAroundAPathIsNotPartOfIt() {
        XCTAssertEqual(paths("(Sources/a.swift:12)"), ["Sources/a.swift"])
        XCTAssertEqual(paths("in `Sources/a.swift`, later"), ["Sources/a.swift"])
        XCTAssertEqual(paths("the fix is in Sources/a.swift."), ["Sources/a.swift"])
        XCTAssertEqual(lines("(Sources/a.swift:12)"), [12])
    }

    func testTheRangeCoversThePathAndItsLineTogether() {
        let text = "see Sources/a.swift:12 now"
        let candidate = CodePath.candidates(in: Array(text.utf8))[0]
        XCTAssertEqual(candidate.range.lowerBound, 4)
        XCTAssertEqual(candidate.range.upperBound, 22)
        XCTAssertEqual(
            Array(text.utf8).text(in: candidate.range), "Sources/a.swift:12")
    }

    func testAColumnIsDroppedRatherThanKept() {
        XCTAssertEqual(paths("Sources/a.swift:12:7"), ["Sources/a.swift"])
        XCTAssertEqual(lines("Sources/a.swift:12:7"), [12])
    }
}
