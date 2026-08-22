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

    // MARK: - Bins

    func testEachRowIsNamedByWhatFillsIt() {
        // Two blocks, the first filling the top half of the strip.
        let bins = DocumentMap.bins(
            classes: [.code, .prose], rows: 4, total: 100,
            height: { $0 == 0 ? 50 : 50 })
        XCTAssertEqual(bins.map(\.dominant), [.code, .code, .prose, .prose])
    }

    /// The property the map lives or dies by on a long document: one diagram
    /// inside a wall of prose still leaves a mark.
    func testSomethingSmallInsideALongStretchIsStillRecorded() {
        var classes = [DocumentMap.Kind](repeating: .prose, count: 100)
        classes[50] = .diagram
        let bins = DocumentMap.bins(
            classes: classes, rows: 10, total: 1000, height: { _ in 10 })
        XCTAssertTrue(bins.contains { $0.has(.diagram) })
        // And the row it landed in is prose by height, so the dash matters.
        XCTAssertEqual(bins[5].dominant, .diagram)
    }

    func testABlockWithNoHeightTakesNoRoomOnTheStrip() {
        // What a block inside a closed section comes to.
        let bins = DocumentMap.bins(
            classes: [.table, .prose], rows: 4, total: 100,
            height: { $0 == 0 ? 0 : 100 })
        XCTAssertFalse(bins.contains { $0.has(.table) })
        XCTAssertEqual(Set(bins.map(\.dominant)), [.prose])
    }

    func testRowsBelowTheEndOfTheDocumentStayEmpty() {
        let bins = DocumentMap.bins(
            classes: [.prose], rows: 4, total: 100, height: { _ in 50 })
        XCTAssertFalse(bins[0].isEmpty)
        XCTAssertTrue(bins[3].isEmpty)
    }

    func testAnEmptyDocumentBinsToNothingRatherThanCrashing() {
        XCTAssertEqual(
            DocumentMap.bins(classes: [], rows: 3, total: 0, height: { _ in 0 }).count, 3)
        XCTAssertTrue(
            DocumentMap.bins(classes: [.prose], rows: 0, total: 10, height: { _ in 10 })
                .isEmpty)
    }

    /// The rows of a real strip are finer than a line of type — a few hundred
    /// points of strip against a document of thousands — so a heading gets rows
    /// of its own rather than being averaged into the prose around it.
    func testAHeadingGetsItsOwnRows() {
        let bins = DocumentMap.bins(
            classes: [.prose, .heading, .prose], rows: 20, total: 100,
            height: { [45, 10, 45][$0] })
        XCTAssertEqual(bins[9].dominant, .heading)
        XCTAssertEqual(bins[0].dominant, .prose)
        XCTAssertEqual(bins[19].dominant, .prose)
    }

    /// And where a row holds both in similar measure, the thing that is not
    /// prose names it: prose is the background a reader is scanning past.
    func testProseYieldsTheRowToWhateverElseIsInIt() {
        let bins = DocumentMap.bins(
            classes: [.prose, .table], rows: 1, total: 100,
            height: { [60, 40][$0] })
        XCTAssertEqual(bins[0].dominant, .table)
        // Twice as much prose does win it back, which is what "half" means.
        let mostlyProse = DocumentMap.bins(
            classes: [.prose, .table], rows: 1, total: 100,
            height: { [80, 20][$0] })
        XCTAssertEqual(mostlyProse[0].dominant, .prose)
    }
}
