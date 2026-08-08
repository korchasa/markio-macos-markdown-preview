import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// What the diagram reader takes and what it refuses.
@MainActor
final class MermaidTests: XCTestCase {
    private func flowchart(_ source: String) -> Flowchart? {
        guard case .flowchart(let chart)? = MermaidDiagram.parse(source) else { return nil }
        return chart
    }

    private func sequence(_ source: String) -> SequenceDiagram? {
        guard case .sequence(let diagram)? = MermaidDiagram.parse(source) else { return nil }
        return diagram
    }

    func testNodesShapesAndEdges() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    A[Open] --> B{Big?}
                    B -->|yes| C(Later)
                    B -->|no| D([Now])
                    C --> D
                """
            )
        )
        XCTAssertEqual(chart.direction, .down)
        XCTAssertEqual(chart.nodes.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(chart.nodes.map(\.label), ["Open", "Big?", "Later", "Now"])
        XCTAssertEqual(chart.nodes.map(\.shape), [.rectangle, .diamond, .rounded, .stadium])
        XCTAssertEqual(chart.edges.count, 4)
        XCTAssertEqual(chart.edges[1].label, "yes")
        XCTAssertTrue(chart.edges[0].arrow)
    }

    func testAChainIsAsManyEdgesAsItHasArrows() throws {
        let chart = try XCTUnwrap(flowchart("graph LR\n  A --> B --> C"))
        XCTAssertEqual(chart.direction, .right)
        XCTAssertEqual(chart.nodes.count, 3)
        XCTAssertEqual(chart.edges.map { [$0.from, $0.to] }, [[0, 1], [1, 2]])
    }

    func testTheKindsOfLine() throws {
        let chart = try XCTUnwrap(
            flowchart("flowchart LR\n A ==> B\n B -.-> C\n C --- D")
        )
        XCTAssertEqual(chart.edges.map(\.stroke), [.thick, .dotted, .solid])
        XCTAssertEqual(chart.edges.map(\.arrow), [true, true, false])
    }

    /// A node named once and shaped later is one node, not two.
    func testANodeMentionedTwiceKeepsOneIdentity() throws {
        let chart = try XCTUnwrap(flowchart("flowchart TD\n A --> B\n B[Done]"))
        XCTAssertEqual(chart.nodes.count, 2)
        XCTAssertEqual(chart.nodes[1].label, "Done")
    }

    func testWhatItRefuses() {
        // Each of these has to come back nil, because drawing what is left after
        // ignoring the rest would be a different diagram.
        for source in [
            "pie title Where the time goes\n  \"Parsing\" : 40",
            "flowchart BT\n A --> B",
            "flowchart TD\n subgraph one\n A --> B\n end",
            "flowchart TD\n A ~~~ B",
            "classDiagram\n class A",
            "flowchart TD",
            "",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testParticipantsAndMessages() throws {
        let diagram = try XCTUnwrap(
            sequence(
                """
                sequenceDiagram
                    participant V as View
                    participant L as Layout
                    V->>L: box(at:)
                    L-->>V: a block
                    V->>V: draw
                """
            )
        )
        XCTAssertEqual(diagram.participants.map(\.label), ["View", "Layout"])
        XCTAssertEqual(diagram.messages.map(\.text), ["box(at:)", "a block", "draw"])
        XCTAssertEqual(diagram.messages.map(\.dashed), [false, true, false])
        XCTAssertEqual(diagram.messages[2].from, diagram.messages[2].to)
    }

    /// A participant nobody declared is still a participant, in the order the
    /// messages first name them.
    func testUndeclaredParticipantsAppearInOrderOfUse() throws {
        let diagram = try XCTUnwrap(sequence("sequenceDiagram\n A->>B: hi\n C->>A: later"))
        XCTAssertEqual(diagram.participants.map(\.id), ["A", "B", "C"])
    }

    func testSequenceConstructsItCannotDraw() {
        for source in [
            "sequenceDiagram\n loop every day\n A->>B: hi\n end",
            "sequenceDiagram\n Note right of A: thinking",
            "sequenceDiagram\n participant A",
            "sequenceDiagram\n A B C",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testADrawnDiagramReplacesItsFenceButKeepsItsText() throws {
        let source = """
            ```mermaid
            flowchart TD
                A[One] --> B[Two]
            ```
            """
        let document = Document(text: source)
        let layout = DocumentLayout(
            document: document, theme: Theme(isDark: false), columnWidth: 520)
        let box = try XCTUnwrap(layout.box(at: 0))
        // Nothing is typeset: the picture is all decorations.
        XCTAssertTrue(box.segments.isEmpty)
        XCTAssertGreaterThan(box.decorations.count, 5)
        XCTAssertGreaterThan(box.height, 80)
        // The fence's own text stays findable and copyable.
        XCTAssertEqual(box.plainText, "flowchart TD\n    A[One] --> B[Two]")
        XCTAssertEqual(box.codeRegion?.language, "mermaid")
    }

    func testAFenceItCannotDrawIsStillACodeBlock() throws {
        let document = Document(text: "```mermaid\npie title Costs\n```")
        let layout = DocumentLayout(
            document: document, theme: Theme(isDark: false), columnWidth: 520)
        let box = try XCTUnwrap(layout.box(at: 0))
        XCTAssertFalse(box.segments.isEmpty)
    }
}
