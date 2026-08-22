import XCTest

@testable import MarkdownKit

/// Sorting and filtering a table the reader is looking at, without touching
/// what the document says.
final class TableArrangementTests: XCTestCase {
    private let source = """
        | Task | Minutes | Owner |
        | --- | --- | --- |
        | Backfill | 40 | ann |
        | Verify | 9 | Bo |
        | Ship | 120 | cy |
        """

    private func table(_ text: String) -> HTMLTable {
        let document = Document(text: text)
        let leaf = document.leaves.first { document.blocks[Int($0)].kind == .table }
        return HTMLTable(gfm: document.table(at: leaf!), document: document)
    }

    private func column(_ table: HTMLTable, _ index: Int) -> [String] {
        table.cells
            .filter { $0.column == index && !$0.isHeader }
            .sorted { $0.row < $1.row }
            .map(HTMLTable.text(of:))
    }

    func testClickingAHeaderSortsAndClickingAgainReverses() {
        let source = table(self.source)
        var arrangement = TableArrangement().clicking(column: 0)
        XCTAssertEqual(column(source.arranged(by: arrangement), 0), ["Backfill", "Ship", "Verify"])
        arrangement = arrangement.clicking(column: 0)
        XCTAssertEqual(column(source.arranged(by: arrangement), 0), ["Verify", "Ship", "Backfill"])
    }

    func testAThirdClickGivesTheDocumentItsOwnOrderBack() {
        let source = table(self.source)
        let arrangement = TableArrangement()
            .clicking(column: 0).clicking(column: 0).clicking(column: 0)
        XCTAssertTrue(arrangement.isPlain)
        XCTAssertEqual(column(source.arranged(by: arrangement), 0), ["Backfill", "Verify", "Ship"])
    }

    /// 9 before 40 before 120 — the order a reader means by "sort by minutes",
    /// and the opposite of what sorting the strings would give.
    func testNumbersSortAsNumbers() {
        let sorted = table(source).arranged(by: TableArrangement(column: 1))
        XCTAssertEqual(column(sorted, 1), ["9", "40", "120"])
    }

    func testTextSortsWithoutCaringAboutCase() {
        let sorted = table(source).arranged(by: TableArrangement(column: 2))
        XCTAssertEqual(column(sorted, 2), ["ann", "Bo", "cy"])
    }

    func testEqualValuesKeepTheOrderTheDocumentPutThemIn() {
        let same = table(
            """
            | Name | Group |
            | --- | --- |
            | first | a |
            | second | a |
            | third | a |
            """)
        let sorted = same.arranged(by: TableArrangement(column: 1))
        XCTAssertEqual(column(sorted, 0), ["first", "second", "third"])
    }

    func testTheFilterKeepsRowsThatMatchAnyCell() {
        let filtered = table(source).arranged(by: TableArrangement(filter: "an"))
        // "Backfill" matches on its owner, "ann"; nothing else does.
        XCTAssertEqual(column(filtered, 0), ["Backfill"])
    }

    func testTheFilterIgnoresCase() {
        XCTAssertEqual(
            column(table(source).arranged(by: TableArrangement(filter: "SHIP")), 0),
            ["Ship"])
    }

    func testTheHeaderStaysWhereItIs() {
        let sorted = table(source).arranged(by: TableArrangement(column: 1))
        XCTAssertEqual(sorted.headerRow, 0)
        XCTAssertEqual(sorted.headerCells.map(HTMLTable.text(of:)), ["Task", "Minutes", "Owner"])
    }

    /// A merged cell makes a row something other than a row, so the table keeps
    /// its header inert instead of moving text that belongs to a neighbour.
    func testATableWithAMergedCellRefusesToSort() {
        let merged = HTMLTable.parse(
            Array(
                """
                <table>
                <tr><th>Name</th><th>Note</th></tr>
                <tr><td rowspan="2">shared</td><td>b</td></tr>
                <tr><td>a</td></tr>
                </table>
                """.utf8))!
        XCTAssertFalse(merged.canRearrange)
        let asked = merged.arranged(by: TableArrangement(column: 1))
        XCTAssertEqual(
            asked.cells.map(HTMLTable.text(of:)), merged.cells.map(HTMLTable.text(of:)))
    }

    func testAPlainArrangementCostsNothing() {
        let source = table(self.source)
        XCTAssertTrue(TableArrangement().isPlain)
        XCTAssertEqual(
            source.arranged(by: TableArrangement()).cells.map(HTMLTable.text(of:)),
            source.cells.map(HTMLTable.text(of:)))
    }
}
