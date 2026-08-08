import XCTest

@testable import MarkdownKit

/// Block structure: what the scanner makes of headings, lists, quotes, code,
/// tables and the ways they nest.
final class BlockScannerTests: XCTestCase {
    private func assertTree(
        _ markdown: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let document = Document(text: markdown)
        XCTAssertEqual(TreeDump.dump(document), expected, file: file, line: line)
    }

    func testHeadingsAndParagraphs() {
        assertTree(
            """
            # Title

            Some text
            over two lines.

            ## Second ##
            """,
            """
            h1 "Title"
            para "Some text\\nover two lines."
            h2 "Second"
            """
        )
    }

    func testSetextHeadings() {
        assertTree(
            """
            Title
            =====

            Subtitle
            --------
            """,
            """
            h1(setext) "Title"
            h2(setext) "Subtitle"
            """
        )
    }

    func testThematicBreakVersusSetext() {
        assertTree(
            """
            ---

            ***
            """,
            """
            hr
            hr
            """
        )
    }

    func testFencedCodeKeepsBlankLinesAndMarkers() {
        assertTree(
            """
            ```swift
            let a = 1

            # not a heading
            ```
            """,
            """
            code(fenced,swift) "let a = 1\\n\\n# not a heading"
            """
        )
    }

    func testIndentedCode() {
        assertTree(
            """
            text

                indented
                code

            after
            """,
            """
            para "text"
            code(indented) "indented\\ncode"
            para "after"
            """
        )
    }

    func testTightAndLooseLists() {
        assertTree(
            """
            - one
            - two

            1. first

            2. second
            """,
            """
            list(bullet,tight)
              item
                para "one"
              item
                para "two"
            list(ordered,loose)
              item
                para "first"
              item
                para "second"
            """
        )
    }

    func testNestedListsAndQuotes() {
        assertTree(
            """
            - outer
              - inner
                continued
            > quoted
            > > deeper
            """,
            """
            list(bullet,tight)
              item
                para "outer"
                list(bullet,tight)
                  item
                    para "inner\\ncontinued"
            quote
              para "quoted"
              quote
                para "deeper"
            """
        )
    }

    func testLazyContinuationInsideQuote() {
        assertTree(
            """
            > first
            lazy continuation

            > done
            """,
            """
            quote
              para "first\\nlazy continuation"
            quote
              para "done"
            """
        )
    }

    func testCodeBlockInsideListItem() {
        assertTree(
            """
            - item

              ```
              code
              ```
            """,
            """
            list(bullet,loose)
              item
                para "item"
                code(fenced) "code"
            """
        )
    }

    func testTable() {
        assertTree(
            """
            | A | B |
            | --- | ---: |
            | 1 | 2 |
            """,
            """
            table(2) "| A | B |\\n| --- | ---: |\\n| 1 | 2 |"
            """
        )
    }

    func testTableNeedsMatchingColumnCount() {
        assertTree(
            """
            | A | B |
            | --- |
            """,
            """
            para "| A | B |\\n| --- |"
            """
        )
    }

    func testFrontMatter() {
        assertTree(
            """
            ---
            title: Test
            ---

            Body
            """,
            """
            frontmatter "title: Test"
            para "Body"
            """
        )
    }

    func testHTMLBlockEndsAtBlankLine() {
        assertTree(
            """
            <div class="x">
            raw
            </div>

            after
            """,
            """
            html "<div class="x">\\nraw\\n</div>"
            para "after"
            """
        )
    }

    func testInlineTagStaysInParagraph() {
        assertTree(
            """
            Press <kbd>Cmd</kbd> to go.
            """,
            """
            para "Press <kbd>Cmd</kbd> to go."
            """
        )
    }

    func testLinkReferenceDefinitionsAreLifted() {
        let document = Document(
            text: """
                [ref]: https://example.com "Title"

                See [ref].
                """
        )
        XCTAssertEqual(TreeDump.dump(document), "para \"See [ref].\"")
        XCTAssertEqual(document.references.count, 1)
        let reference = try? XCTUnwrap(document.references["ref"])
        XCTAssertEqual(document.text(reference!.destination), "https://example.com")
        XCTAssertEqual(document.text(reference!.title), "Title")
    }

    func testEmptyDocument() {
        let document = Document(text: "")
        XCTAssertTrue(document.isEmpty)
        XCTAssertEqual(document.headings(), [])
    }

    func testHeadingSlugsDeduplicate() {
        let document = Document(
            text: """
                # Setup
                ## Setup
                ### Привет мир
                """
        )
        XCTAssertEqual(document.headings().map(\.slug), ["setup", "setup-1", "привет-мир"])
    }
}
