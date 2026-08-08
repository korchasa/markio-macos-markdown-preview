import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Find and rendering must agree on what a block says.
///
/// `BlockPlainText` reproduces, without a font or a theme, the exact characters
/// `AttributedBuilder` puts on screen — that is what lets a search run over a
/// huge document without typesetting any of it. The two are written separately
/// on purpose, so this test is what keeps them from drifting: a match offset
/// from one is used to highlight a range in the other, and a one-character
/// disagreement puts the highlight on the wrong word.
@MainActor
final class PlainTextParityTests: XCTestCase {
    private func assertParity(
        _ markdown: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let document = Document(text: markdown)
        let layout = DocumentLayout(
            document: document,
            theme: Theme(isDark: false),
            columnWidth: 520
        )
        XCTAssertGreaterThan(
            layout.blockCount, 0, "fixture produced no blocks", file: file, line: line)
        for ordinal in 0..<layout.blockCount {
            guard let box = layout.box(at: ordinal) else {
                XCTFail("no box for ordinal \(ordinal)", file: file, line: line)
                continue
            }
            XCTAssertEqual(
                BlockPlainText.text(document: document, leaf: document.leaves[ordinal]),
                box.plainText,
                "ordinal \(ordinal)",
                file: file,
                line: line
            )
        }
    }

    func testProse() {
        assertParity(
            """
            # A heading with `code` in it

            Ordinary prose with *emphasis*, **strong**, ~~struck~~ and a
            soft-wrapped second line.

            A paragraph with a [link](https://example.com), an ![image](a.png)
            and an &amp; entity.

            A line ending in two spaces\u{20}\u{20}
            forces a hard break.
            """
        )
    }

    /// A formula that is typeset occupies a placeholder; one that is not keeps
    /// its source. Find has to make the same choice as the renderer for both.
    func testMath() {
        assertParity(
            """
            Euler wrote $e^{i\\pi} + 1 = 0$, and the quadratic root is
            $x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$.

            This one is beyond it: $\\begin{matrix} a & b \\end{matrix}$, so it
            stays as written.
            """
        )
    }

    func testHTMLTable() {
        assertParity(
            """
            <table>
            <tr><th rowspan="2">Stage</th><th colspan="2">Cost</th></tr>
            <tr><th>Time</th><th>Memory</th></tr>
            <tr><td>Parse</td><td>69 ms</td><td>12.2 MB</td></tr>
            </table>
            """
        )
    }

    func testFootnotes() {
        assertParity(
            """
            A claim.[^1] Another claim,[^long] and an undefined one.[^gone]

            [^1]: The first note.
            [^long]: A note with `code` in it, running onto
                a second line.
            """
        )
    }

    func testListsAndQuotes() {
        assertParity(
            """
            - A bullet
            - Another with **bold**
              - Nested
            - [ ] Unfinished
            - [x] Finished

            1. First
            2. Second

            > Quoted prose
            >
            > > Nested quote
            """
        )
    }

    func testCodeAndTables() {
        assertParity(
            """
            ```swift
            let x = 1  // a comment
            print("hello")
            ```

                indented code

            | Left | Centre | Right |
            | :--- | :----: | ----: |
            | a    | b      | c     |
            | longer cell | x | y |

            ---
            """
        )
    }

    func testTerminalOutputAndDiffs() {
        let escape = "\u{1B}"
        assertParity(
            """
            ```
            \(escape)[32mok\(escape)[0m and \(escape)[1;31mfailed\(escape)[0m
            \(escape)[38;5;208mextended\(escape)[0m
            ```

            ```diff
            @@ -1,3 +1,3 @@
             context line
            -removed line
            +added line
            ```
            """
        )
    }

    func testFrontMatterAndHTML() {
        assertParity(
            """
            ---
            title: Something
            ---

            Text with <b>bold</b>, <kbd>⌘F</kbd> and a <br> break.

            <div class="raw">
            raw block
            </div>
            """
        )
    }
}
