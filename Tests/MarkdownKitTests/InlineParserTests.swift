import XCTest

@testable import MarkdownKit

/// Inline structure: emphasis, code spans, links, images, entities, breaks and
/// the inline HTML tags that map onto a native text style.
final class InlineParserTests: XCTestCase {
    private func assertInline(
        _ markdown: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(InlineDump.dump(markdown), expected, file: file, line: line)
    }

    func testEmphasisAndStrong() {
        assertInline("*one* **two** ***three***", "{i:one} {b:two} {b:{i:three}}")
    }

    func testUnderscoreEmphasisInsideWordIsLiteral() {
        assertInline("snake_case_name", "snake_case_name")
        assertInline("_real emphasis_", "{i:real emphasis}")
    }

    func testUnmatchedDelimitersStayLiteral() {
        assertInline("a * b", "a * b")
        assertInline("**bold", "**bold")
    }

    func testStrikethrough() {
        assertInline("~~gone~~ and ~kept~", "{s:gone} and ~kept~")
    }

    func testCodeSpans() {
        assertInline("use `let x = 1` now", "use {c:let x = 1} now")
        assertInline("``a ` b``", "{c:a ` b}")
        assertInline("`` ` ``", "{c:`}")
    }

    func testCodeSpanBeatsEmphasis() {
        assertInline("`*not emphasis*`", "{c:*not emphasis*}")
    }

    func testInlineLink() {
        assertInline("[text](https://a.b)", "{l(https://a.b):text}")
        assertInline("[text](<https://a.b> \"t\")", "{l(https://a.b):text}")
    }

    func testEmphasisInsideLinkText() {
        assertInline("[*em*](u)", "{l(u):{i:em}}")
    }

    func testImage() {
        assertInline("![alt](pic.png)", "{img(pic.png)}{l(pic.png):alt}")
    }

    func testAutolink() {
        assertInline("<https://a.b>", "{l(https://a.b):https://a.b}")
        assertInline("<a@b.c>", "{l(mailto:a@b.c):a@b.c}")
    }

    func testReferenceLink() {
        let document = Document(
            text: """
                [ref]: https://example.com

                See [ref] and [label][ref].
                """
        )
        let leaf = document.leaves[0]
        XCTAssertEqual(
            InlineDump.dump(document: document, leaf: leaf),
            "See {l(https://example.com):ref} and {l(https://example.com):label}."
        )
    }

    func testUnresolvedReferenceStaysLiteral() {
        assertInline("See [missing].", "See [missing].")
    }

    func testEscapes() {
        assertInline("\\*not em\\*", "*not em*")
        assertInline("a \\\\ b", "a \\ b")
    }

    func testEntities() {
        assertInline("A &amp; B &#8212; C &#x2014; D", "A & B — C — D")
        assertInline("not&anentity;", "not&anentity;")
    }

    func testBreaks() {
        assertInline("a  \nb", "a⏎b")
        assertInline("a\\\nb", "a⏎b")
        assertInline("a\nb", "a↵b")
    }

    func testInlineHTMLStyles() {
        assertInline("Press <kbd>Cmd</kbd>.", "Press {k:Cmd}.")
        assertInline("<mark>hit</mark>", "{h:hit}")
        assertInline("<b>x</b> <i>y</i> <u>z</u>", "{b:x} {i:y} {u:z}")
        assertInline("line<br>next", "line⏎next")
        assertInline("E = mc<sup>2</sup>", "E = mc{^:2}")
        assertInline("H<sub>2</sub>O", "H{v:2}O")
    }

    func testUnknownTagsAreDropped() {
        assertInline("<span data-x=\"1\">kept text</span>", "kept text")
    }

    func testMath() {
        assertInline("Euler: $e^{i\\pi}+1=0$ done", "Euler: {m:e^{i\\pi}+1=0} done")
        assertInline("costs $5 and $10", "costs $5 and $10")
    }

    func testTaskListMarker() {
        let document = Document(text: "- [x] done\n- [ ] todo")
        let checked = document.content(of: document.leaves[0])
        let unchecked = document.content(of: document.leaves[1])
        XCTAssertEqual(
            document.taskMarker(in: checked, leaf: document.leaves[0]),
            Document.TaskMarker(isChecked: true, contentStart: 4)
        )
        XCTAssertEqual(
            document.taskMarker(in: unchecked, leaf: document.leaves[1]),
            Document.TaskMarker(isChecked: false, contentStart: 4)
        )
    }

    func testTableCells() {
        let document = Document(
            text: """
                | A | B |
                | :-- | --: |
                | 1 | `a|b` |
                """
        )
        let table = document.table(at: document.leaves[0])
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.header.map { document.text($0) }, ["A", "B"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].map { document.text($0) }, ["1", "`a|b`"])
    }
}
