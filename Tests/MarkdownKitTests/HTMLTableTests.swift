import XCTest

@testable import MarkdownKit

/// Tables written with tags, including the merges Markdown's own syntax cannot
/// express — which is the entire reason this parser exists.
final class HTMLTableTests: XCTestCase {
    private func parse(_ html: String) -> HTMLTable? {
        HTMLTable.parse(Array(html.utf8))
    }

    /// One line per cell: `row,column +rowspan×columnspan text`.
    private func dump(_ table: HTMLTable) -> String {
        table.cells.map { cell in
            let span =
                cell.rowspan == 1 && cell.columnspan == 1
                ? "" : " +\(cell.rowspan)x\(cell.columnspan)"
            let header = cell.isHeader ? "th" : "td"
            return "\(cell.row),\(cell.column) \(header)\(span) "
                + String(decoding: cell.content, as: UTF8.self)
        }.joined(separator: "\n")
    }

    func testAPlainGrid() throws {
        let table = try XCTUnwrap(
            parse(
                """
                <table>
                <tr><th>A</th><th>B</th></tr>
                <tr><td>1</td><td>2</td></tr>
                </table>
                """
            )
        )
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(
            dump(table),
            """
            0,0 th A
            0,1 th B
            1,0 td 1
            1,1 td 2
            """
        )
    }

    func testACellSpanningDownPushesTheNextRowAcross() throws {
        // The second row has one cell written, and it must land in column 1
        // because the row above reaches down into column 0.
        let table = try XCTUnwrap(
            parse(
                """
                <table>
                <tr><td rowspan="2">tall</td><td>right of it</td></tr>
                <tr><td>pushed across</td></tr>
                </table>
                """
            )
        )
        XCTAssertEqual(
            dump(table),
            """
            0,0 td +2x1 tall
            0,1 td right of it
            1,1 td pushed across
            """
        )
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.columnCount, 2)
    }

    func testColumnSpansAndAlignment() throws {
        let table = try XCTUnwrap(
            parse(
                """
                <table>
                <tr><th colspan="2" align="center">Both</th></tr>
                <tr><td style="text-align: right">one</td><td>two</td></tr>
                </table>
                """
            )
        )
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.cells[0].columnspan, 2)
        XCTAssertEqual(table.cells[0].alignment, .center)
        XCTAssertEqual(table.cells[1].alignment, .right)
        XCTAssertEqual(table.cells[2].alignment, .none)
    }

    func testCellsKeepTheirInlineMarkup() throws {
        let table = try XCTUnwrap(
            parse("<table><tr><td>a <b>bold</b> word</td></tr></table>")
        )
        XCTAssertEqual(
            String(decoding: table.cells[0].content, as: UTF8.self),
            "a <b>bold</b> word"
        )
    }

    func testWhatIsNotATableIsNotOne() {
        // Each of these has to come back nil so the caller shows the source
        // instead of half a table.
        XCTAssertNil(parse("<div><tr><td>x</td></tr></div>"))
        XCTAssertNil(parse("<table><tr><td>never closed"))
        XCTAssertNil(parse("<table></table>"))
        XCTAssertNil(parse("<table><tr><td><table><tr><td>x</td></tr></table></td></tr></table>"))
    }

    func testATableSplitByABlankLineIsNotParsedAtAll() {
        // The scanner ends an HTML block at a blank line, so the block never
        // holds the closing tag — and a table without one is not a table.
        let document = Document(
            text: """
                <table>
                <tr><td>one</td></tr>

                <tr><td>two</td></tr>
                </table>
                """
        )
        XCTAssertNil(HTMLTable.parse(document.content(of: document.leaves[0])))
    }
}
