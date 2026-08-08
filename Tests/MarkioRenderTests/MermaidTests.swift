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
            "flowchart TD\n A ~~~ B",
            // A frame inside a frame, a subgraph left open, and one closed twice.
            "flowchart TD\n subgraph a\n subgraph b\n A --> B\n end\n end",
            "flowchart TD\n subgraph a\n A --> B",
            "flowchart TD\n A --> B\n end",
            // A direction inside a subgraph turns that frame's own contents.
            "flowchart TD\n subgraph a\n direction LR\n A --> B\n end",
            // A colour and a property this cannot draw.
            "flowchart TD\n A --> B\n style A fill:chartreuse",
            "flowchart TD\n A --> B\n style A opacity:0.5",
            "flowchart TD\n A --> B\n class A missing",
            "flowchart TD\n A:::missing --> B",
            "flowchart TD\n A --> B\n click A \"https://example.com\"",
            "flowchart TD",
            "",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testTheOtherTwoDirections() throws {
        XCTAssertEqual(try XCTUnwrap(flowchart("graph BT\n A --> B")).direction, .up)
        XCTAssertEqual(try XCTUnwrap(flowchart("graph RL\n A --> B")).direction, .left)
    }

    func testTheRestOfTheShapes() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    A{{Hex}} --> B[[Call]]
                    B --> C[(Store)]
                    C --> D[/Slant/]
                    D --> E[\\Other\\]
                    E --> F[/Funnel\\]
                    F --> G[\\Cup/]
                    G --> H>Flag]
                    H --> I(((Deep)))
                """
            )
        )
        XCTAssertEqual(
            chart.nodes.map(\.shape),
            [
                .hexagon, .subroutine, .cylinder, .parallelogram, .parallelogramAlt,
                .trapezoid, .trapezoidAlt, .flag, .doubleCircle,
            ]
        )
        XCTAssertEqual(chart.nodes.map(\.label).first, "Hex")
    }

    /// `-- text -->` writes the words inside the arrow instead of after it.
    func testALabelWrittenInsideTheArrow() throws {
        let chart = try XCTUnwrap(
            flowchart("flowchart LR\n A -- asks --> B\n B -. waits .-> C\n C == sends ==> D")
        )
        XCTAssertEqual(chart.edges.map(\.label), ["asks", "waits", "sends"])
        XCTAssertEqual(chart.edges.map(\.stroke), [.solid, .dotted, .thick])
        XCTAssertTrue(chart.edges.allSatisfy(\.arrow))
    }

    func testASubgraphKeepsTheNodesDeclaredInsideIt() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    Start --> Read
                    subgraph work[Doing the work]
                        Read --> Write
                    end
                    Write --> Done
                """
            )
        )
        XCTAssertEqual(chart.groups.count, 1)
        XCTAssertEqual(chart.groups[0].title, "Doing the work")
        // A node belongs to the frame it is first written in, and `Read` was
        // already named on the line above.
        XCTAssertEqual(chart.groups[0].members.map { chart.nodes[$0].id }, ["Write"])
    }

    func testStylesReachTheNodesTheyName() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    classDef warn fill:#fee,stroke:red
                    A --> B
                    B --> C:::warn
                    class A warn
                    style B fill:#fff,stroke-width:3
                """
            )
        )
        let pale = Flowchart.Colour(red: 1, green: 238 / 255, blue: 238 / 255)
        XCTAssertEqual(chart.nodes[0].style.fill, pale)
        XCTAssertEqual(chart.nodes[0].style.stroke, Flowchart.Colour(red: 1, green: 0, blue: 0))
        XCTAssertEqual(chart.nodes[1].style.strokeWidth, 3)
        XCTAssertEqual(chart.nodes[2].style.fill, chart.nodes[0].style.fill)
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
            "sequenceDiagram\n Note right of A: thinking",
            "sequenceDiagram\n participant A",
            "sequenceDiagram\n A B C",
            // A block left open, one closed twice, and a note with no placement.
            "sequenceDiagram\n loop forever\n A->>B: hi",
            "sequenceDiagram\n A->>B: hi\n end",
            "sequenceDiagram\n A->>B: hi\n Note A: thinking",
            // A tinted band and a participant box are frames this does not draw.
            "sequenceDiagram\n rect rgb(0,0,0)\n A->>B: hi\n end",
            "sequenceDiagram\n box Team\n participant A\n end\n A->>B: hi",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testBlocksNestAndKeepTheirArms() throws {
        let diagram = try XCTUnwrap(
            sequence(
                """
                sequenceDiagram
                    autonumber
                    A->>B: ask
                    alt found
                        B-->>A: here
                    else missing
                        loop three times
                            B->>B: look again
                        end
                        B-->>A: sorry
                    end
                """
            )
        )
        XCTAssertTrue(diagram.autonumber)
        XCTAssertEqual(diagram.items.count, 2)
        guard case .block(let alt) = diagram.items[1] else {
            return XCTFail("the second item is the alt block")
        }
        XCTAssertEqual(alt.kind, "alt")
        XCTAssertEqual(alt.sections.map(\.title), ["found", "missing"])
        guard case .block(let loop) = alt.sections[1].items[0] else {
            return XCTFail("the else arm opens a loop")
        }
        XCTAssertEqual(loop.kind, "loop")
        // Every message is still reachable, however deep it sits.
        XCTAssertEqual(diagram.messages.map(\.text), ["ask", "here", "look again", "sorry"])
    }

    func testNotesAndActivationAndTheOtherArrowHeads() throws {
        let diagram = try XCTUnwrap(
            sequence(
                """
                sequenceDiagram
                    Note over A,B: two of them
                    Note left of A: thinking
                    A->>+B: work
                    B--)A: eventually
                    B-->>-A: done
                    activate A
                    A-xB: give up
                    deactivate A
                """
            )
        )
        guard case .note(let over) = diagram.items[0], case .note(let left) = diagram.items[1]
        else { return XCTFail("the diagram opens with two notes") }
        XCTAssertEqual(over.placement, .over)
        XCTAssertEqual(over.participants.count, 2)
        XCTAssertEqual(left.placement, .leftOf)
        XCTAssertEqual(diagram.messages.map(\.head), [.arrow, .open, .arrow, .cross])
        XCTAssertTrue(diagram.messages[0].activates)
        XCTAssertTrue(diagram.messages[2].deactivates)
        if case .activate(let index) = diagram.items[5] {
            XCTAssertEqual(diagram.participants[index].id, "A")
        } else {
            XCTFail("`activate A` is an item of its own")
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
