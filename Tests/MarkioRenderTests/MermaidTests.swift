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

    func testAPieChartIsItsSlicesAndItsTitle() throws {
        guard
            case .pie(let chart)? = MermaidDiagram.parse(
                """
                pie showData title Where the time goes
                    "Parsing" : 12
                    "Layout" : 48
                    Drawing : 40
                """
            )
        else { return XCTFail("a pie chart") }
        XCTAssertEqual(chart.title, "Where the time goes")
        XCTAssertTrue(chart.showData)
        XCTAssertEqual(chart.slices.map(\.label), ["Parsing", "Layout", "Drawing"])
        XCTAssertEqual(chart.total, 100)
    }

    func testWhatAPieRefuses() {
        for source in [
            "pie title Costs",
            "pie\n \"Parsing\" : none",
            "pie\n \"Parsing\" : 0",
            "pie something else\n \"Parsing\" : 1",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// A state machine is read into a flowchart: the shapes carry what makes it
    /// a state machine, so it needs no layout of its own.
    func testAStateMachineBecomesAFlowchart() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                stateDiagram-v2
                    direction LR
                    state "Waiting for a file" as Idle
                    [*] --> Idle
                    Idle --> Busy: open
                    Busy --> [*]
                """
            )
        )
        XCTAssertEqual(chart.direction, .right)
        XCTAssertEqual(chart.nodes.map(\.shape), [.point, .rounded, .rounded, .endPoint])
        XCTAssertEqual(chart.nodes[1].label, "Waiting for a file")
        XCTAssertEqual(chart.edges[1].label, "open")
    }

    func testWhatAStateMachineRefuses() {
        for source in [
            // A machine inside a machine, a fork bar, a note, a plain word.
            "stateDiagram-v2\n state Big {\n [*] --> A\n }",
            "stateDiagram-v2\n state fork <<fork>>\n [*] --> fork",
            "stateDiagram-v2\n [*] --> A\n note right of A: waiting",
            "stateDiagram-v2\n A",
            "stateDiagram-v2",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    private func boxes(_ source: String) -> BoxDiagram? {
        guard case .boxes(let diagram)? = MermaidDiagram.parse(source) else { return nil }
        return diagram
    }

    func testAClassDiagramReadsItsMembersAndItsRelations() throws {
        let diagram = try XCTUnwrap(
            boxes(
                """
                classDiagram
                    class Animal {
                        +String name
                        +isMammal() bool
                    }
                    class Duck
                    Duck : +swim()
                    <<interface>> Flyer
                    Animal <|-- Duck
                    Animal "1" o-- "many" Leg : has
                    Duck ..> Flyer
                """
            )
        )
        XCTAssertEqual(diagram.boxes.map(\.name), ["Animal", "Duck", "Flyer", "Leg"])
        // A member with brackets is a call and goes in the second compartment.
        XCTAssertEqual(diagram.boxes[0].compartments, [["+String name"], ["+isMammal() bool"]])
        XCTAssertEqual(diagram.boxes[1].compartments, [[], ["+swim()"]])
        XCTAssertEqual(diagram.boxes[2].stereotype, "interface")
        XCTAssertEqual(diagram.links.map(\.fromEnd), [.triangle, .hollowDiamond, .none])
        XCTAssertEqual(diagram.links.map(\.toEnd), [.none, .none, .arrow])
        XCTAssertEqual(diagram.links.map(\.dashed), [false, false, true])
        XCTAssertEqual(diagram.links[1].fromCount, "1")
        XCTAssertEqual(diagram.links[1].toCount, "many")
        XCTAssertEqual(diagram.links[1].label, "has")
    }

    func testAnEntityDiagramReadsItsCrowsFeet() throws {
        let diagram = try XCTUnwrap(
            boxes(
                """
                erDiagram
                    CUSTOMER ||--o{ ORDER : places
                    ORDER }|..|{ LINE-ITEM : contains
                    CUSTOMER {
                        string email PK
                    }
                """
            )
        )
        XCTAssertEqual(diagram.boxes.map(\.name), ["CUSTOMER", "ORDER", "LINE-ITEM"])
        // The name is written before its type, the way a table reads.
        XCTAssertEqual(diagram.boxes[0].compartments, [["email  string  PK"]])
        XCTAssertEqual(diagram.links.map(\.fromEnd), [.one, .oneOrMore])
        XCTAssertEqual(diagram.links.map(\.toEnd), [.zeroOrMore, .oneOrMore])
        XCTAssertEqual(diagram.links.map(\.dashed), [false, true])
    }

    func testWhatTheBoxDiagramsRefuse() {
        for source in [
            // A note, a namespace and a click handler are not drawn.
            "classDiagram\n class A\n note \"hello\"",
            "classDiagram\n namespace one {\n class A\n }",
            "classDiagram\n class A\n click A href \"x\"",
            "classDiagram\n A B C",
            "classDiagram",
            // A relation with an end this does not know, and an unclosed block.
            "erDiagram\n A |>--o{ B : x",
            "erDiagram\n A {\n string name",
            "erDiagram",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testAMindmapIsATreeReadFromItsIndentation() throws {
        guard
            case .mindmap(let map)? = MermaidDiagram.parse(
                """
                mindmap
                  root((Markio))
                    Parser
                      Blocks
                      Inline
                    Renderer
                      CoreText
                """
            )
        else { return XCTFail("expected a mindmap") }
        XCTAssertEqual(
            map.nodes.map(\.label),
            ["Markio", "Parser", "Blocks", "Inline", "Renderer", "CoreText"])
        XCTAssertEqual(map.nodes.map(\.depth), [0, 1, 2, 2, 1, 2])
        XCTAssertEqual(map.nodes[0].shape, .circle)
        XCTAssertEqual(map.nodes[0].children, [1, 4])
        XCTAssertEqual(map.nodes[1].children, [2, 3])
        XCTAssertEqual(map.nodes[4].children, [5])
    }

    func testAMindmapKeepsTheShapeItsBracketsAskFor() throws {
        guard
            case .mindmap(let map)? = MermaidDiagram.parse(
                "mindmap\n  root[Square]\n    a(Rounded)\n    b{{Hexagon}}\n    Plain"
            )
        else { return XCTFail("expected a mindmap") }
        XCTAssertEqual(map.nodes.map(\.shape), [.rectangle, .rounded, .hexagon, .rounded])
        XCTAssertEqual(map.nodes.map(\.label), ["Square", "Rounded", "Hexagon", "Plain"])
    }

    func testATimelineGroupsItsPeriodsIntoSections() throws {
        guard
            case .timeline(let timeline)? = MermaidDiagram.parse(
                """
                timeline
                    title History
                    section Writing
                      2023 : First draft : Outline
                      2024 : Review
                    section Shipping
                      2025 : Release
                      : Site
                """
            )
        else { return XCTFail("expected a timeline") }
        XCTAssertEqual(timeline.title, "History")
        XCTAssertEqual(timeline.sections, ["Writing", "Shipping"])
        XCTAssertEqual(timeline.periods.map(\.title), ["2023", "2024", "2025"])
        XCTAssertEqual(timeline.periods.map(\.section), [0, 0, 1])
        XCTAssertEqual(timeline.periods[0].events, ["First draft", "Outline"])
        // A bare `:` line adds to the period written above it.
        XCTAssertEqual(timeline.periods[2].events, ["Release", "Site"])
    }

    func testWhatTheTreeDiagramsRefuse() {
        for source in [
            // An icon and a class are decoration the layout has no place for.
            "mindmap\n  root\n    ::icon(fa fa-book)",
            "mindmap\n  root\n    a\n  second root",
            // A cloud and a bang need paths this does not draw.
            "mindmap\n  root\n    id)Cloud(",
            "mindmap",
            "timeline",
            "timeline\n    section",
            "timeline\n    : an event with no period",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testTheTreeDiagramsAreDrawnWhole() throws {
        for source in [
            "mindmap\n  root((Markio))\n    Parser\n      Blocks\n    Renderer",
            "timeline\n    title History\n    2023 : Draft\n    2024 : Review",
        ] {
            let document = Document(text: "```mermaid\n\(source)\n```")
            let layout = DocumentLayout(
                document: document, theme: Theme(isDark: false), columnWidth: 520)
            let box = try XCTUnwrap(layout.box(at: 0))
            XCTAssertTrue(box.segments.isEmpty, source)
            XCTAssertGreaterThan(box.decorations.count, 8, source)
            XCTAssertGreaterThan(box.height, 80, source)
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
