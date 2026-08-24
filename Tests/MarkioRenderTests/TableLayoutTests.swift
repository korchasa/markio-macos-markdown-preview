import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// What a rearranged table looks like once it has been laid out: which rows are
/// drawn, where the header sits, and what the rest of the app can still find.
@MainActor
final class TableLayoutTests: XCTestCase {
    /// Five body rows, which is enough for the filter row to be worth its own
    /// line — see `showsFilter` in the layout engine.
    private let markdown = """
        # Report

        | Task | Minutes |
        | --- | --- |
        | Backfill | 40 |
        | Verify | 9 |
        | Ship | 120 |
        | Review | 15 |
        | Announce | 3 |
        """

    private func makeLayout(_ text: String) -> DocumentLayout {
        DocumentLayout(
            document: Document(text: text), theme: Theme(isDark: false), columnWidth: 520)
    }

    /// The table's cells in reading order, from the box that is actually drawn.
    private func rows(_ layout: DocumentLayout, at ordinal: Int = 1) -> [String] {
        layout.box(at: ordinal)!.plainText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\t").map(String.init).joined(separator: " ") }
    }

    func testTheTableIsLaidOutInTheOrderTheDocumentWroteIt() {
        let layout = makeLayout(markdown)
        XCTAssertEqual(
            rows(layout),
            [
                "Task Minutes", "Backfill 40", "Verify 9", "Ship 120", "Review 15", "Announce 3",
            ])
    }

    func testClickingAHeaderSortsTheDrawnTableAndClickingAgainReversesIt() {
        let layout = makeLayout(markdown)
        layout.clickTableHeader(at: 1, column: 1)
        XCTAssertEqual(
            rows(layout).dropFirst().map { $0.split(separator: " ").last.map(String.init)! },
            ["3", "9", "15", "40", "120"])
        layout.clickTableHeader(at: 1, column: 1)
        XCTAssertEqual(
            rows(layout).dropFirst().map { $0.split(separator: " ").last.map(String.init)! },
            ["120", "40", "15", "9", "3"])
        layout.clickTableHeader(at: 1, column: 1)
        XCTAssertTrue(layout.arrangement(at: 1).isPlain)
        XCTAssertEqual(rows(layout).dropFirst().first, "Backfill 40")
    }

    func testTheFilterRowHidesTheRowsThatDoNotMatch() {
        let layout = makeLayout(markdown)
        layout.setArrangement(TableArrangement(filter: "ver"), at: 1)
        // "Verify" matches on its name; nothing else in the table holds "ver".
        XCTAssertEqual(rows(layout), ["Task Minutes", "Verify 9"])
    }

    /// A filtered-away row is hidden from the picture, not from the document —
    /// so find, which reads the source, still walks straight to it.
    func testFindStillFindsTextInAFilteredAwayRow() async {
        let document = Document(text: markdown)
        let layout = makeLayout(markdown)
        layout.setArrangement(TableArrangement(filter: "ver"), at: 1)
        XCTAssertFalse(rows(layout).contains { $0.contains("Announce") })

        let engine = FindEngine()
        let matches = await withCheckedContinuation { continuation in
            var resumed = false
            engine.search("Announce", in: document) { result in
                guard result.isComplete, !resumed else { return }
                resumed = true
                continuation.resume(returning: result.matches)
            }
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.ordinal, 1)
    }

    func testTheTableReportsWhereItsHeaderAndFilterRowAre() {
        let layout = makeLayout(markdown)
        let region = layout.box(at: 1)!.tableRegion!
        XCTAssertTrue(region.canRearrange)
        XCTAssertEqual(region.headers.map(\.column), [0, 1])
        XCTAssertEqual(region.headerRect.minY, region.rect.minY, accuracy: 0.5)
        // The filter row sits directly under the header, inside the table.
        let filter = region.filterRect!
        XCTAssertEqual(filter.minY, region.headerRect.maxY, accuracy: 0.5)
        XCTAssertLessThan(filter.maxY, region.rect.maxY)
        // Every header cell is inside the header strip, so a click on one lands.
        for header in region.headers {
            XCTAssertTrue(region.headerRect.insetBy(dx: -1, dy: -1).contains(header.rect))
        }
    }

    /// The sort mark stands where the heading is not.
    ///
    /// It used to sit against the right edge of the cell whatever the column
    /// was aligned to, so on a right-aligned column it landed on the last
    /// letter of the heading — `Time` came out as `Timē` in a store picture.
    func testTheSortMarkKeepsOffARightAlignedHeading() {
        let text = """
            # Report

            | Task | Minutes |
            | --- | ---: |
            | Backfill | 40 |
            | Verify | 9 |
            | Ship | 120 |
            | Review | 15 |
            | Announce | 3 |
            """
        let layout = makeLayout(text)
        layout.setArrangement(TableArrangement(column: 1, ascending: false), at: 1)
        let box = layout.box(at: 1)!
        let cell = box.tableRegion!.headers.first { $0.column == 1 }!.rect
        var marks: [CGRect] = []
        for decoration in box.decorations {
            guard case .path(let path, _, _, let filled) = decoration, filled else { continue }
            let bounds = path.boundingBox
            guard cell.insetBy(dx: -1, dy: -1).contains(bounds) else { continue }
            marks.append(bounds)
        }
        XCTAssertEqual(marks.count, 1, "one sort mark inside the sorted heading's cell")
        // Against the left edge, which is the half a right-aligned heading
        // leaves empty.
        XCTAssertLessThan(marks[0].maxX, cell.midX)
    }

    // MARK: - The header that stays put

    private func region(_ layout: DocumentLayout) -> BlockBox.TableRegion {
        layout.box(at: 1)!.tableRegion!
    }

    func testAHeaderStillOnScreenIsNotPinned() {
        let region = region(makeLayout(markdown))
        XCTAssertNil(
            DocumentView.stickyHeaderStrip(
                region: region, blockTop: 40,
                visible: CGRect(x: 0, y: 0, width: 600, height: 400), width: 600))
    }

    func testAHeaderScrolledOffTheTopIsPinnedToIt() {
        let region = region(makeLayout(markdown))
        let strip = DocumentView.stickyHeaderStrip(
            region: region, blockTop: 0,
            visible: CGRect(x: 0, y: 30, width: 600, height: 400), width: 600)
        XCTAssertEqual(strip?.minY, 30)
        XCTAssertEqual(strip?.height, region.headerRect.height)
        XCTAssertEqual(strip?.width, 600)
    }

    /// The point of the test: a pinned header must not outlive the table it
    /// belongs to, hanging over the prose that follows it.
    func testThePinnedHeaderGoesWhenTheTableDoes() {
        let region = region(makeLayout(markdown))
        let below = region.rect.maxY - region.headerRect.height / 2
        XCTAssertNil(
            DocumentView.stickyHeaderStrip(
                region: region, blockTop: 0,
                visible: CGRect(x: 0, y: below, width: 600, height: 400), width: 600))
    }

    /// The strip is drawn from the block's own box, so a table that is no
    /// longer laid out has no header to pin — there is nothing left to draw it
    /// from. This is the property that test states.
    func testAShortTableIsLeftAsTheDocumentDrewIt() {
        let layout = makeLayout(
            """
            | Task | Minutes |
            | --- | --- |
            | Backfill | 40 |
            """)
        XCTAssertNil(layout.box(at: 0)!.tableRegion?.filterRect)
    }

    func testATypedFilterBringsTheRowBackOnAShortTableToo() {
        let layout = makeLayout(
            """
            | Task | Minutes |
            | --- | --- |
            | Backfill | 40 |
            """)
        layout.filterEditing = 0
        XCTAssertNotNil(layout.box(at: 0)!.tableRegion?.filterRect)
    }

    /// A printed page has nobody to type into a filter row, so it does not get
    /// one — and the table is a row shorter for it.
    func testAPrintedTableHasNoFilterRow() {
        let layout = makeLayout(markdown)
        let withFilter = layout.box(at: 1)!.height
        layout.showsTableFilters = false
        XCTAssertNil(layout.box(at: 1)!.tableRegion?.filterRect)
        XCTAssertLessThan(layout.box(at: 1)!.height, withFilter)
    }

    func testATableWithAMergedCellKeepsItsHeaderInert() {
        let layout = makeLayout(
            """
            <table>
            <tr><th>Name</th><th>Note</th></tr>
            <tr><td rowspan="2">shared</td><td>b</td></tr>
            <tr><td>a</td></tr>
            </table>
            """)
        let region = layout.box(at: 0)!.tableRegion!
        XCTAssertFalse(region.canRearrange)
        let before = rows(layout, at: 0)
        layout.clickTableHeader(at: 0, column: 1)
        XCTAssertEqual(rows(layout, at: 0), before)
    }
}
