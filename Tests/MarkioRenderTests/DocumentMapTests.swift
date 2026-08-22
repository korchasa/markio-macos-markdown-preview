import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// What the map says a document is made of, and where it draws it.
final class DocumentMapTests: XCTestCase {
    private func classes(_ text: String) -> [DocumentMap.Kind] {
        let document = Document(text: text)
        return document.leaves.map { DocumentMap.classify(document, leaf: $0) }
    }

    func testEveryKindIsRecognisedFromTheBlockLayerAlone() {
        XCTAssertEqual(classes("# Title"), [.heading])
        XCTAssertEqual(classes("Just prose."), [.prose])
        XCTAssertEqual(classes("```swift\nlet x = 1\n```"), [.code])
        XCTAssertEqual(classes("```mermaid\ngraph TD\n  A-->B\n```"), [.diagram])
        XCTAssertEqual(classes("| A | B |\n| --- | --- |\n| 1 | 2 |"), [.table])
        XCTAssertEqual(classes("---"), [.rule])
        XCTAssertEqual(classes("> quoted"), [.quote])
        XCTAssertEqual(classes("- one\n- two"), [.list, .list])
    }

    /// The one guess in the whole classification, and the shape of its error.
    func testAParagraphThatOpensWithAnImageCountsAsAPicture() {
        XCTAssertEqual(classes("![a picture](pic.png)"), [.picture])
        // Wrong at the edge, on purpose: asking the inline parser instead would
        // mean parsing every paragraph of the document to draw the strip.
        XCTAssertEqual(classes("![a picture](pic.png) and then some prose."), [.picture])
        XCTAssertEqual(classes("Prose with ![a picture](pic.png) inside it."), [.prose])
        // A picture that is the whole of a list item is still a picture: the
        // marker in front of it is scaffolding, not text.
        XCTAssertEqual(classes("- ![a picture](pic.png)"), [.picture])
        XCTAssertEqual(classes("> ![a picture](pic.png)"), [.picture])
    }

    func testATableWrittenWithTagsIsATable() {
        XCTAssertEqual(
            classes("<table>\n<tr><td>one</td></tr>\n</table>"), [.table])
        XCTAssertEqual(classes("<div>\nnot a table\n</div>"), [.code])
    }

    // MARK: - Colours

    /// Both appearances answer for every kind, and they answer differently:
    /// the colours are derived from the palette rather than invented, which is
    /// what keeps light and dark from drifting apart.
    @MainActor
    func testEveryKindHasAColourInBothAppearances() {
        let light = Theme(isDark: false)
        let dark = Theme(isDark: true)
        var seen: Set<[CGFloat]> = []
        for kind in DocumentMap.Kind.allCases {
            let lightColor = light.mapColor(for: kind)
            let darkColor = dark.mapColor(for: kind)
            XCTAssertGreaterThan(lightColor.alpha, 0)
            XCTAssertGreaterThan(darkColor.alpha, 0)
            seen.insert(lightColor.components ?? [])
        }
        // Prose, lists and code are shades of one another on purpose — they are
        // all text — but the nine kinds must not collapse into three.
        XCTAssertGreaterThanOrEqual(seen.count, 6)
    }

    // MARK: - Rows

    private func rows(
        _ text: String, fromLine: Int = 0, maxRows: Int = 40, columns: Int = 40
    ) -> [DocumentMap.Row] {
        let document = Document(text: text)
        let classes = document.leaves.map { DocumentMap.classify(document, leaf: $0) }
        return DocumentMap.rows(
            document: document, classes: classes, fromLine: fromLine,
            maxRows: maxRows, columns: columns)
    }

    /// The whole point of the map: it shows the words, where they are on the
    /// line and how long they run.
    func testALineBecomesOneRunPerWord() {
        let map = rows("one two  three")
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(
            map[0].runs,
            [
                DocumentMap.Run(column: 0, length: 3),
                DocumentMap.Run(column: 4, length: 3),
                DocumentMap.Run(column: 9, length: 5),
            ])
    }

    func testIndentationIsKeptBecauseItIsHalfTheShape() {
        let map = rows("- one\n    - nested")
        XCTAssertEqual(map[0].runs.first?.column, 0)
        XCTAssertEqual(map[1].runs.first?.column, 4)
        // A tab is four columns, as it is nearly everywhere a document is read.
        XCTAssertEqual(rows("\tdeep")[0].runs.first?.column, 4)
    }

    func testABlankLineIsABlankRow() {
        let map = rows("one\n\ntwo")
        XCTAssertEqual(map.count, 3)
        XCTAssertTrue(map[1].isBlank)
        XCTAssertFalse(map[0].isBlank)
    }

    /// A line wider than the map is cut off at its edge. One row to a line is
    /// what lets the reading rectangle land on the line it is marking.
    func testALongLineIsCutOffRatherThanWrapped() {
        let map = rows(String(repeating: "x", count: 25) + " tail", columns: 10)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0].runs, [DocumentMap.Run(column: 0, length: 10)])
        // Every line of the document is a row of the map, in order.
        let three = rows("a\nbb\nccc")
        XCTAssertEqual(three.map(\.line), [0, 1, 2])
    }

    func testARowKnowsWhatBlockItBelongsTo() {
        let map = rows("# Title\n\n```swift\nlet x = 1\n```")
        XCTAssertEqual(map[0].kind, .heading)
        XCTAssertEqual(map[0].ordinal, 0)
        // The fences belong to no block — a code block covers its contents —
        // but they are plainly code, and the map colours them as such.
        XCTAssertEqual(map[2].kind, .code)
        XCTAssertEqual(map[3].kind, .code)
        XCTAssertEqual(map[4].kind, .code)
        XCTAssertEqual(map[3].ordinal, 1)
        // The blank line between the title and the code belongs to no block.
        XCTAssertEqual(map[1].ordinal, -1)
    }

    /// What makes the map affordable on a huge document: it reads the window it
    /// draws and not a byte more.
    func testOnlyTheWindowIsRead() {
        let text = (0..<500).map { "line \($0)" }.joined(separator: "\n")
        let map = rows(text, fromLine: 100, maxRows: 20)
        XCTAssertEqual(map.count, 20)
        XCTAssertEqual(map.first?.line, 100)
        XCTAssertEqual(map.last?.line, 119)
    }

    func testAnAccentedWordIsAsWideAsItLooks() {
        // Two bytes to a letter in UTF-8, one column on the map.
        XCTAssertEqual(rows("привет")[0].runs, [DocumentMap.Run(column: 0, length: 6)])
    }

    func testAnEmptyDocumentMapsToNothingRatherThanCrashing() {
        XCTAssertTrue(rows("").isEmpty)
        XCTAssertTrue(rows("text", maxRows: 0).isEmpty)
        XCTAssertTrue(rows("text", fromLine: 99).isEmpty)
    }

    /// A click on the map lands on a block, and this is the arithmetic that
    /// takes it there.
    func testALineFindsTheBlockThatOwnsIt() {
        let document = Document(text: "# Title\n\nProse.\n\n- one\n- two")
        XCTAssertEqual(DocumentMap.leafIndex(document, covering: 0), 0)
        XCTAssertEqual(DocumentMap.leafIndex(document, covering: 2), 1)
        XCTAssertEqual(DocumentMap.firstLine(document, ordinal: 1), 2)
        XCTAssertEqual(DocumentMap.rowCount(document), document.lines.count)
    }
}
