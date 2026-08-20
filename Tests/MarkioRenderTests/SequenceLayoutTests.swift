import AppKit
import XCTest

@testable import MarkioRender

/// How wide a sequence diagram stands, and how far a `box` colour reaches.
@MainActor
final class SequenceLayoutTests: XCTestCase {
    private let wordy =
        "a message with enough words in it to want a great deal of room, more room "
        + "than three columns standing side by side would ever have given it"

    private func diagram(_ body: String) -> String {
        """
        sequenceDiagram
            participant P1 as First
            participant P2 as Second
            participant P3 as Third
            participant P4 as Fourth
        \(body)
        """
    }

    private func width(_ source: String) throws -> Int {
        let image = try XCTUnwrap(
            DocumentRenderer.diagram(source: source, theme: Theme(isDark: false), width: 6000))
        return image.width
    }

    func testAGapIsOnlyAsWideAsWhatCrossesIt() throws {
        // One wordy message between the last pair, and short ones elsewhere.
        // One spacing for every column would hand all three gaps the room this
        // one message needs, and the picture would be as wide as the diagram
        // whose every message is wordy.
        let one = try width(
            diagram(
                """
                    P1->>P2: ok
                    P2->>P3: ok
                    P3->>P4: \(wordy)
                """))
        let every = try width(
            diagram(
                """
                    P1->>P2: \(wordy)
                    P2->>P3: \(wordy)
                    P3->>P4: \(wordy)
                """))
        XCTAssertLessThan(Double(one), Double(every) * 0.75)
    }

    func testAMessageCrossingSeveralColumnsAsksThemTogether() throws {
        // The same message, spread over three gaps instead of sitting in one.
        // It needs the three to add up to its own width, so the picture is no
        // wider than the one where it crosses a single gap — narrower, in
        // fact, since the other two gaps were already holding it up. Asking
        // each crossed gap for the whole width instead makes it three times
        // the size.
        let across = try width(
            diagram(
                """
                    P1->>P4: \(wordy)
                """))
        let alongside = try width(
            diagram(
                """
                    P3->>P4: \(wordy)
                """))
        XCTAssertLessThanOrEqual(across, alongside)
    }

    func testABoxColoursTheWholeColumnAndNotJustItsHeading() throws {
        let source = diagram(
            """
                box rgb(210,236,214) Cluster
                    participant P2
                    participant P3
                end
                P1->>P2: one
                P2->>P3: two
                P3->>P4: three
                P4->>P1: four
                P1->>P3: five
            """)
        let parsed = try XCTUnwrap(MermaidDiagram.parse(source))
        let drawing = MermaidLayout.draw(parsed, theme: Theme(isDark: false), width: 900)
        // The group's own fill: the widest filled rectangle that is not the
        // page behind the picture.
        var tallest = CGRect.zero
        for case .path(let path, _, _, true) in drawing.decorations {
            let box = path.boundingBox
            if box.width > 100, box.height > tallest.height { tallest = box }
        }
        XCTAssertGreaterThan(
            tallest.height, drawing.contentRect.height * 0.7,
            "a box colour should run the height of the column it names")
        XCTAssertEqual(tallest.maxY, drawing.contentRect.maxY, accuracy: 2)
    }
}
