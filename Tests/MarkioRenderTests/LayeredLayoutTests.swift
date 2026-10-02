import XCTest

@testable import MarkioRender

/// How graphs of boxes joined by lines are laid out, judged by where the parts
/// came to rest rather than by pixels.
@MainActor
final class LayeredLayoutTests: XCTestCase {
    private func geometry(_ source: String) throws -> MermaidLayout.Geometry? {
        let diagram = try XCTUnwrap(MermaidDiagram.parse(source), "did not parse")
        return MermaidLayout.draw(diagram, theme: Theme(isDark: false), width: 2000).geometry
    }

    /// The layout bench counts faults on this, so it has to say which line is
    /// which box's and where each line's words were put.
    func testAFlowchartHandsOutItsBoxesLinesAndWords() throws {
        let drawn = try XCTUnwrap(
            geometry(
                """
                flowchart TD
                    A[Open] -->|first| B[Read]
                    B --> C[Close]
                    C --> C
                """
            ))
        XCTAssertEqual(drawn.nodes.count, 3)
        XCTAssertEqual(drawn.lines.map(\.ends), [[0, 1], [1, 2], [2]])
        XCTAssertEqual(drawn.lines.map(\.loop), [false, false, true])
        XCTAssertNotNil(drawn.lines[0].label)
        XCTAssertNil(drawn.lines[1].label)
        for line in drawn.lines { XCTAssertGreaterThanOrEqual(line.points.count, 2) }
        // A line runs from the border of one box to the border of the other.
        let first = drawn.lines[0].points
        XCTAssertEqual(first[0].y, drawn.nodes[0].maxY, accuracy: 1)
        XCTAssertEqual(first[first.count - 1].y, drawn.nodes[1].minY, accuracy: 1)
    }

    /// A line that ends on a frame may touch everything inside that frame.
    func testALineToAFrameOwnsWhatTheFrameHolds() throws {
        let drawn = try XCTUnwrap(
            geometry(
                """
                flowchart LR
                    outside --> group
                    subgraph group [Group]
                        one --> two
                    end
                """
            ))
        XCTAssertEqual(drawn.frames.count, 1)
        let toFrame = try XCTUnwrap(drawn.lines.first { $0.ends.count == 3 })
        XCTAssertEqual(Set(toFrame.ends).count, 3)
    }

    func testAClassDiagramHandsOutItsRelations() throws {
        let drawn = try XCTUnwrap(
            geometry(
                """
                erDiagram
                    SOURCE ||--o{ ITEM : yields
                    ITEM }o--|| STORY : "belongs to"
                """
            ))
        XCTAssertEqual(drawn.nodes.count, 3)
        XCTAssertEqual(drawn.lines.count, 2)
        XCTAssertTrue(drawn.lines.allSatisfy { $0.label != nil })
    }

    /// Kinds whose geometry is fixed by the diagram itself are not graphs to
    /// lay out, and say so by handing out nothing.
    func testASequenceDiagramHasNoGraphGeometry() throws {
        XCTAssertNil(try geometry("sequenceDiagram\n    A->>B: hi"))
    }
}
