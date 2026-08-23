import XCTest

@testable import MarkdownKit

/// GFM's autolink extension: addresses nobody marked up.
///
/// The hard half is not finding them, it is deciding where they stop. A URL at
/// the end of a sentence is followed by a full stop that belongs to the
/// sentence; a link inside an aside is followed by a bracket that closes the
/// aside. Both are here, with the cases where the same characters do belong to
/// the link.
final class ExtendedAutolinkTests: XCTestCase {
    private func assertInline(
        _ markdown: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(InlineDump.dump(markdown), expected, file: file, line: line)
    }

    func testABareURLIsALink() {
        assertInline(
            "see https://example.com/a for more",
            "see {l(https://example.com/a):https://example.com/a} for more")
        assertInline("http://example.com", "{l(http://example.com):http://example.com}")
    }

    func testWWWGetsAScheme() {
        assertInline("www.example.com", "{l(http://www.example.com):www.example.com}")
    }

    func testAnAddressIsAMailtoLink() {
        assertInline(
            "write to test@example.com now",
            "write to {l(mailto:test@example.com):test@example.com} now")
    }

    func testTheSentenceKeepsItsPunctuation() {
        assertInline(
            "at www.example.com.",
            "at {l(http://www.example.com):www.example.com}.")
        assertInline(
            "see https://example.com/a, then",
            "see {l(https://example.com/a):https://example.com/a}, then")
        assertInline(
            "mail test@example.com.",
            "mail {l(mailto:test@example.com):test@example.com}.")
    }

    func testABracketBelongsToWhicheverOpenedIt() {
        // The aside's bracket is not part of the path…
        assertInline(
            "(see https://example.com/a)",
            "(see {l(https://example.com/a):https://example.com/a})")
        // …and the path's own bracket is.
        assertInline(
            "https://example.com/a_(b)",
            "{l(https://example.com/a_(b)):https://example.com/a_(b)}")
    }

    func testAnEntityAtTheEndIsNotPartOfTheLink() {
        assertInline(
            "https://example.com/a&amp;",
            "{l(https://example.com/a):https://example.com/a}&")
    }

    func testALinkHasToStartSomewhere() {
        // Inside a word, nothing is a link.
        assertInline("notwww.example.com", "notwww.example.com")
        assertInline("xhttps://example.com", "xhttps://example.com")
        // A domain needs a period, and no underscore in its last two segments.
        assertInline("www.example", "www.example")
        assertInline("http://a_b.com", "http://a_b.com")
        assertInline("http://example.com", "{l(http://example.com):http://example.com}")
    }

    func testAnAddressNeedsBothSides() {
        assertInline("@example.com", "@example.com")
        assertInline("test@example", "test@example")
        assertInline("test@example.com_", "test@example.com_")
    }

    func testTheMarkedUpFormsStillWin() {
        // The angle-bracket autolink keeps its own text, and a link written out
        // keeps the text the author gave it.
        assertInline("<https://example.com>", "{l(https://example.com):https://example.com}")
        assertInline(
            "[the site](https://example.com)", "{l(https://example.com):the site}")
    }

    /// A link inside a link is not a link.
    ///
    /// This is the case that decides where bare scanning is allowed at all: the
    /// scan runs to the first space, so inside link text it would swallow the
    /// `](destination)` that follows and wreck both links.
    func testNoBareLinkInsideLinkText() {
        assertInline(
            "[see https://example.com](https://other.example)",
            "{l(https://other.example):see https://example.com}")
    }

    /// A destination is not prose either.
    ///
    /// The brackets have closed by the time the scan reaches the destination,
    /// so without a rule of its own the same URL became a second link over the
    /// same bytes — invisible on screen, and one link too many in the document.
    func testNoBareLinkInsideADestination() {
        let document = Document(text: "[the site](https://example.com)")
        let leaf = document.leaves[0]
        let parsed = InlineParser.parse(
            content: document.content(of: leaf),
            references: document.references,
            documentBytes: document.bytes)
        XCTAssertEqual(parsed.links.map(\.destination), ["https://example.com"])
    }

    func testCodeIsNotScannedForLinks() {
        assertInline("`https://example.com`", "{c:https://example.com}")
    }

    func testCaseDoesNotMatter() {
        assertInline("HTTPS://Example.com", "{l(HTTPS://Example.com):HTTPS://Example.com}")
        assertInline("WWW.example.com", "{l(http://WWW.example.com):WWW.example.com}")
    }
}
