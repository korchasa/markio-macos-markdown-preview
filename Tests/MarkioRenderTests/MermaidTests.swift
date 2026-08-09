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
        XCTAssertEqual(
            chart.edges.map { [$0.from, $0.to] }, [[.node(0), .node(1)], [.node(1), .node(2)]])
    }

    func testTheKindsOfLine() throws {
        let chart = try XCTUnwrap(
            flowchart("flowchart LR\n A ==> B\n B -.-> C\n C --- D")
        )
        XCTAssertEqual(chart.edges.map(\.stroke), [.thick, .dotted, .solid])
        XCTAssertEqual(chart.edges.map(\.arrow), [true, true, false])
    }

    /// A link written to hold two boxes apart and draw nothing.
    func testAnInvisibleLinkRanksTheBoxesAndDrawsNoLine() throws {
        let chart = try XCTUnwrap(flowchart("flowchart TD\n A ~~~ B"))
        XCTAssertEqual(chart.edges.map(\.stroke), [.invisible])
        XCTAssertFalse(chart.edges[0].arrow)
        // Held one under the other, the picture is taller than it is wide.
        let held = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "flowchart TD\n A ~~~ B", theme: Theme(isDark: false), width: 700))
        let apart = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "flowchart TD\n A\n B", theme: Theme(isDark: false), width: 700))
        XCTAssertGreaterThan(held.height, apart.height)
    }

    /// Every colour name CSS knows, written any of the ways CSS writes one.
    func testAColourIsReadByNameByHexAndByItsNumbers() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    A --> B --> C --> D
                    style A fill:chartreuse
                    style B fill:rgb(255, 0, 0)
                    style C fill:rgba(0, 0, 255, 0.5)
                    style D fill:#00ff0080
                """))
        XCTAssertEqual(
            chart.nodes[0].style.fill, Flowchart.Colour(red: 127.0 / 255, green: 1, blue: 0))
        XCTAssertEqual(chart.nodes[1].style.fill, Flowchart.Colour(red: 1, green: 0, blue: 0))
        XCTAssertEqual(
            chart.nodes[2].style.fill, Flowchart.Colour(red: 0, green: 0, blue: 1, alpha: 0.5))
        XCTAssertEqual(chart.nodes[3].style.fill?.alpha, 128.0 / 255)
    }

    /// A share of the page shows through a faded node, and a link named by its
    /// number is painted on its own.
    func testANodeFadesAndALinkIsPaintedByItsNumber() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    A --> B
                    B --> C
                    style A opacity:0.5
                    linkStyle 1 stroke:red,stroke-width:2px
                    click A "https://example.com" "Open"
                """))
        XCTAssertEqual(chart.nodes[0].style.opacity, 0.5)
        XCTAssertNil(chart.edges[0].style.stroke)
        XCTAssertEqual(chart.edges[1].style.stroke, Flowchart.Colour(red: 1, green: 0, blue: 0))
        XCTAssertEqual(chart.edges[1].style.strokeWidth, 2)
        // A click cannot be followed in a picture, so it changes nothing drawn.
        XCTAssertTrue(chart.nodes[0].style.fill == nil)
    }

    /// A node named once and shaped later is one node, not two.
    func testANodeMentionedTwiceKeepsOneIdentity() throws {
        let chart = try XCTUnwrap(flowchart("flowchart TD\n A --> B\n B[Done]"))
        XCTAssertEqual(chart.nodes.count, 2)
        XCTAssertEqual(chart.nodes[1].label, "Done")
    }

    /// A name with nothing written under it is a diagram with nothing in it,
    /// which Mermaid draws as an empty picture. An empty picture can leave
    /// nothing out, so there is no half-truth to refuse here.
    func testANameWithNothingUnderItDrawsAnEmptyPicture() throws {
        for kind in [
            "flowchart TD", "stateDiagram-v2", "sequenceDiagram", "classDiagram", "erDiagram",
            "mindmap", "kanban", "timeline", "journey", "gantt", "quadrantChart", "xychart-beta",
            "gitGraph", "packet-beta", "requirementDiagram", "sankey-beta", "treemap-beta",
            "radar-beta", "block-beta", "zenuml", "architecture-beta", "C4Context", "pie",
        ] {
            guard case .empty(let name)? = MermaidDiagram.parse(kind) else {
                return XCTFail("\(kind) is a kind this knows")
            }
            XCTAssertEqual(name, kind)
            XCTAssertNotNil(
                DocumentRenderer.diagram(
                    source: kind, theme: Theme(isDark: false), width: 520), kind)
        }
        // A name it does not know is still not a diagram.
        XCTAssertNil(MermaidDiagram.parse("wobbleDiagram"))
        // A title over an empty picture is still written on the page.
        guard case .titled("Costs", .empty)? = MermaidDiagram.parse("pie title Costs") else {
            return XCTFail("an empty pie keeps its name")
        }
    }

    func testWhatItRefuses() {
        // Each of these has to come back nil, because drawing what is left after
        // ignoring the rest would be a different diagram.
        for source in [
            // A subgraph left open, and one closed twice.
            "flowchart TD\n subgraph a\n A --> B",
            "flowchart TD\n A --> B\n end",
            // A direction nobody knows.
            "flowchart TD\n subgraph a\n direction sideways\n A --> B\n end",
            // A colour, a share and a property this cannot draw.
            "flowchart TD\n A --> B\n style A fill:chartruse",
            "flowchart TD\n A --> B\n style A opacity:2",
            "flowchart TD\n A --> B\n style A rotate:30deg",
            "flowchart TD\n A --> B\n class A missing",
            "flowchart TD\n A:::missing --> B",
            // A line, and a click, naming something nobody wrote.
            "flowchart TD\n A --> B\n linkStyle 4 stroke:red",
            "flowchart TD\n A --> B\n click Z \"https://example.com\"",
            "",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// A frame written inside a frame is drawn inside it.
    func testAFrameHoldsAFrame() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    subgraph outer
                        subgraph inner
                            A --> B
                        end
                        C --> A
                    end
                """))
        XCTAssertEqual(chart.groups.map(\.title), ["outer", "inner"])
        XCTAssertEqual(chart.groups.map(\.parent), [nil, 0])
        // A box belongs to the innermost frame it was written in, and the frame
        // around that one reaches it through its child rather than directly.
        XCTAssertEqual(chart.groups[1].members.count, 2)
        XCTAssertEqual(chart.groups[0].members.count, 1)
    }

    /// `direction` turns whatever it is written in and nothing else.
    func testAFrameCanTurnItsOwnContents() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart LR
                    subgraph one
                        direction TB
                        a --> b
                    end
                    subgraph two
                        c --> d
                    end
                """))
        XCTAssertEqual(chart.direction, .right)
        XCTAssertEqual(chart.groups.map(\.direction), [.down, nil])
        // At the top level the same word is the header's own.
        let turned = try XCTUnwrap(flowchart("flowchart TD\n direction LR\n a --> b"))
        XCTAssertEqual(turned.direction, .right)
    }

    /// A longer line is the same line, and it keeps its head: `--->` points.
    func testALongerArrowStillPoints() throws {
        let chart = try XCTUnwrap(
            flowchart("flowchart LR\n A ---> B\n B ----> C\n C ---- D\n D ===> E"))
        XCTAssertEqual(chart.edges.map(\.arrow), [true, true, false, true])
        XCTAssertEqual(chart.edges.map(\.stroke), [.solid, .solid, .solid, .thick])
    }

    /// An edge to a `subgraph` ends on the frame's border, not on any box.
    func testAnEdgeCanNameAFrame() throws {
        let chart = try XCTUnwrap(
            flowchart("flowchart LR\n subgraph one\n a --> b\n end\n outside --> one"))
        // The word `one` is the frame, so it makes no box of its own: only the
        // two boxes inside the frame and the one outside it.
        XCTAssertEqual(chart.nodes.map(\.id), ["a", "b", "outside"])
        XCTAssertEqual(chart.edges.last?.from, .node(2))
        XCTAssertEqual(chart.edges.last?.to, .frame(0))

        // A frame with a title of its own is still named by its identifier.
        let titled = try XCTUnwrap(
            flowchart("flowchart LR\n subgraph one[First]\n a --> b\n end\n outside --> one"))
        XCTAssertEqual(titled.groups.map(\.title), ["First"])
        XCTAssertEqual(titled.edges.last?.to, .frame(0))

        // A title in quotes names no frame, so a node may share the words.
        let quoted = try XCTUnwrap(
            flowchart("flowchart LR\n subgraph \"First step\"\n a --> b\n end\n c --> a"))
        XCTAssertEqual(quoted.edges.last?.to, .node(0))
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
        // A node belongs to the frame it is written inside. `Read` was named on
        // the line above as well, and that does not take it out of the frame —
        // the frame is where the author drew it.
        XCTAssertEqual(chart.groups[0].members.map { chart.nodes[$0].id }, ["Read", "Write"])
        // `Start` and `Done` were never written inside, so they stay outside.
        XCTAssertEqual(chart.nodes.map(\.id), ["Start", "Read", "Write", "Done"])
    }

    /// One node cannot stand in two frames, so the first frame to use it keeps
    /// it and the second draws without it.
    func testANodeUsedByTwoFramesStaysInTheFirst() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                flowchart TD
                    subgraph one
                        a --> shared
                    end
                    subgraph two
                        shared --> b
                    end
                """
            )
        )
        XCTAssertEqual(
            chart.groups.map { $0.members.map { chart.nodes[$0].id } },
            [
                ["a", "shared"], ["b"],
            ])
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
            "sequenceDiagram\n A B C",
            // A block left open, one closed twice, and a note with no placement.
            "sequenceDiagram\n loop forever\n A->>B: hi",
            "sequenceDiagram\n A->>B: hi\n end",
            "sequenceDiagram\n A->>B: hi\n Note A: thinking",
            // A band asking for a colour nobody has.
            "sequenceDiagram\n rect wobble\n A->>B: hi\n end",
            // A box around participants with a stranger standing between them.
            "sequenceDiagram\n participant A\n participant B\n participant C\n"
                + "box Team\n participant A\n participant C\n end\n A->>B: hi\n B->>C: on",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// A wash of colour behind a run of messages, and a band above a team.
    func testASequenceTintsABandAndBoxesATeam() throws {
        let diagram = try XCTUnwrap(
            sequence(
                """
                sequenceDiagram
                    box rgba(0, 0, 255, 0.1) Our side
                        participant A
                        participant B
                    end
                    participant C
                    rect rgb(240, 240, 240)
                        A->>B: hi
                    end
                    B->>C: on
                """))
        XCTAssertEqual(diagram.groups.map(\.label), ["Our side"])
        XCTAssertEqual(diagram.groups[0].members, [0, 1])
        XCTAssertEqual(diagram.groups[0].fill?.alpha, 0.1)
        guard case .block(let band) = diagram.items.first else {
            return XCTFail("the tinted band is a block of its own")
        }
        XCTAssertEqual(band.kind, "rect")
        XCTAssertEqual(
            band.fill, Flowchart.Colour(red: 240.0 / 255, green: 240.0 / 255, blue: 240.0 / 255))
        // The band and the box are room the picture would not otherwise need.
        let boxed = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "sequenceDiagram\n box Team\n participant A\n participant B\n end\n"
                    + " A->>B: hi", theme: Theme(isDark: false), width: 700))
        let plain = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "sequenceDiagram\n participant A\n participant B\n A->>B: hi",
                theme: Theme(isDark: false), width: 700))
        XCTAssertGreaterThan(boxed.height, plain.height)
    }

    /// Mermaid draws a band and a box whether or not their author gave them a
    /// colour, a name or anybody to hold, so these draw rather than refuse.
    func testABandNeedsNoColourAndABoxNeedsNoName() throws {
        let washed = try XCTUnwrap(
            sequence("sequenceDiagram\n rect\n A->>B: hi\n end"))
        XCTAssertEqual(washed.messages.count, 1)
        XCTAssertNotNil(
            DocumentRenderer.diagram(
                source: "sequenceDiagram\n rect\n A->>B: hi\n end",
                theme: Theme(isDark: false), width: 700))

        let unnamed = try XCTUnwrap(
            sequence("sequenceDiagram\n box\n participant A\n end\n A->>B: hi"))
        XCTAssertEqual(unnamed.groups.count, 1)
        XCTAssertEqual(unnamed.groups[0].label, "")

        let empty = try XCTUnwrap(
            sequence("sequenceDiagram\n box Team\n end\n A->>B: hi"))
        XCTAssertEqual(empty.groups[0].members, [])
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

    /// `state Big { … }` is a machine inside a machine, drawn in a frame of its
    /// own, with a beginning and an end that are its own and not the diagram's.
    func testACompositeStateHoldsItsOwnMachine() throws {
        guard
            case .flowchart(let chart)? = MermaidDiagram.parse(
                """
                stateDiagram-v2
                    [*] --> First
                    state First {
                        [*] --> second
                        second --> [*]
                    }
                    First: A composite
                """)
        else { return XCTFail("a state machine is read into a flowchart") }
        XCTAssertEqual(chart.groups.map(\.id), ["First"])
        // The name the state was given is what the frame wears.
        XCTAssertEqual(chart.groups.map(\.title), ["A composite"])
        // Two beginnings: the diagram's own, and the one inside the frame.
        XCTAssertEqual(chart.nodes.filter { $0.shape == .point }.count, 2)
        XCTAssertEqual(chart.groups[0].members.count, 3)
        // An edge to the composite ends on its frame, not on any state in it.
        XCTAssertEqual(chart.edges.first?.to, .frame(0))
    }

    /// A fork is a bar, a choice is a diamond, and a note is a slip of paper on
    /// a dotted line.
    func testAStateMachineForksChoosesAndCarriesNotes() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                stateDiagram-v2
                    state split <<fork>>
                    state pick <<choice>>
                    state gather <<join>>
                    [*] --> split
                    split --> A
                    split --> B
                    A --> gather
                    B --> gather
                    gather --> pick
                    note right of A : waiting
                    note left of B
                        two lines
                        of words
                    end note
                """))
        let byId = Dictionary(uniqueKeysWithValues: chart.nodes.map { ($0.id, $0) })
        XCTAssertEqual(byId["split"]?.shape, .bar)
        XCTAssertEqual(byId["gather"]?.shape, .bar)
        XCTAssertEqual(byId["pick"]?.shape, .diamond)
        XCTAssertEqual(byId["__note0"]?.shape, .note)
        XCTAssertEqual(byId["__note0"]?.label, "waiting")
        XCTAssertEqual(byId["__note1"]?.label, "two lines<br/>of words")
        // A note hangs on a dotted line with no head on it.
        let dotted = chart.edges.filter { $0.stroke == .dotted }
        XCTAssertEqual(dotted.count, 2)
        XCTAssertTrue(dotted.allSatisfy { !$0.arrow })
        XCTAssertNotNil(
            DocumentRenderer.diagram(
                source: "stateDiagram-v2\n [*] --> A\n note right of A : waiting",
                theme: Theme(isDark: false), width: 700))
    }

    /// A state machine paints its states with the same words a flowchart does.
    func testAStateIsPaintedByItsClass() throws {
        let chart = try XCTUnwrap(
            flowchart(
                """
                stateDiagram-v2
                    [*] --> Crash
                    classDef bad fill:#ff0000
                    class Crash bad
                """))
        let crash = try XCTUnwrap(chart.nodes.first { $0.id == "Crash" })
        XCTAssertEqual(crash.style.fill, Flowchart.Colour(red: 1, green: 0, blue: 0))
    }

    /// A state nobody leaves and a journey step nobody was named for are both
    /// drawn by Mermaid, and both say something a reader wants.
    func testALoneStateStandsAndAStepNeedsNobody() throws {
        guard case .flowchart(let lone)? = MermaidDiagram.parse("stateDiagram-v2\n A") else {
            return XCTFail("a state on its own is still a state")
        }
        XCTAssertEqual(lone.nodes.map(\.id), ["A"])
        XCTAssertEqual(lone.edges.count, 0)

        guard case .journey(let quiet)? = MermaidDiagram.parse("journey\n  Make tea: 5") else {
            return XCTFail("a step with no actors is still a step")
        }
        XCTAssertEqual(quiet.tasks[0].actors, [])
        XCTAssertNotNil(
            DocumentRenderer.diagram(
                source: "journey\n  Make tea: 5", theme: Theme(isDark: false), width: 700))
    }

    func testWhatAStateMachineRefuses() {
        for source in [
            // A machine left open, and a note left open.
            "stateDiagram-v2\n state Big {\n [*] --> A",
            "stateDiagram-v2\n [*] --> A\n note right of A",
            // A note with no words, and a kind of state nobody knows.
            "stateDiagram-v2\n [*] --> A\n note right of A:",
            "stateDiagram-v2\n state pause <<wobble>>\n [*] --> pause",
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
        // Type, then name, then what the line said about it — the order it is
        // written in.
        XCTAssertEqual(diagram.boxes[0].compartments, [["string  email  PK"]])
        XCTAssertEqual(diagram.links.map(\.fromEnd), [.one, .oneOrMore])
        XCTAssertEqual(diagram.links.map(\.toEnd), [.zeroOrMore, .oneOrMore])
        XCTAssertEqual(diagram.links.map(\.dashed), [false, true])
    }

    /// A `note` is a slip of paper, tied to one box or standing on its own.
    func testAClassDiagramReadsItsNotes() throws {
        let diagram = try XCTUnwrap(
            boxes(
                """
                classDiagram
                    note "From Duck till Zebra"
                    Animal <|-- Duck
                    note for Duck "can fly<br>can swim"
                """
            )
        )
        XCTAssertEqual(diagram.notes.map(\.text), ["From Duck till Zebra", "can fly<br>can swim"])
        XCTAssertEqual(diagram.notes.map(\.attached), [nil, 1])
        // A note stands beside the picture rather than inside it, so the words
        // it carries make the drawing wider.
        let plain = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "classDiagram\n Animal <|-- Duck", theme: Theme(isDark: false), width: 900))
        let noted = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "classDiagram\n Animal <|-- Duck\n note for Duck \"can fly\"",
                theme: Theme(isDark: false), width: 900))
        XCTAssertGreaterThan(noted.width, plain.width)
    }

    func testWhatTheBoxDiagramsRefuse() {
        for source in [
            // A note with nothing written on it.
            "classDiagram\n class A\n note",
            "classDiagram\n class A\n note for A",
            // A namespace left open, and a class written in two of them.
            "classDiagram\n namespace one {\n class A",
            "classDiagram\n namespace one {\n class A\n }\n"
                + "namespace two {\n class A\n }",
            // A click, a painting and a class of styles naming nobody.
            "classDiagram\n class A\n click Z href \"x\"",
            "classDiagram\n class A\n style Z fill:red",
            "classDiagram\n class A\n cssClass \"A\" missing",
            "classDiagram\n A B C",
            // A relation with an end this does not know, and an unclosed block.
            "erDiagram\n A |>--o{ B : x",
            "erDiagram\n A {\n string name",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// A namespace is a titled frame around the classes written inside it.
    func testANamespaceFramesTheClassesInsideIt() throws {
        let source = """
            classDiagram
            namespace Shapes {
              class Square
              class Circle
            }
            class Paper
            Paper <|-- Square
            """
        guard case .boxes(let diagram)? = MermaidDiagram.parse(source) else {
            return XCTFail("a class diagram with a namespace is read")
        }
        XCTAssertEqual(diagram.namespaces.map(\.name), ["Shapes"])
        XCTAssertEqual(diagram.boxes.map(\.namespace), [0, 0, nil])
        // The frame is room the picture would not otherwise need.
        let framed = try XCTUnwrap(
            DocumentRenderer.diagram(source: source, theme: Theme(isDark: false), width: 900))
        let loose = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: source.replacingOccurrences(of: "namespace Shapes {", with: "")
                    .replacingOccurrences(of: "}", with: ""),
                theme: Theme(isDark: false), width: 900))
        XCTAssertGreaterThan(framed.height, loose.height)
    }

    /// A class painted by name, and one painted by the class of styles it joins.
    func testAClassIsPaintedByNameAndByItsStyleClass() throws {
        guard
            case .boxes(let diagram)? = MermaidDiagram.parse(
                """
                classDiagram
                class Duck
                class Fish
                classDef pale fill:#eeeeee,stroke:#333333
                cssClass "Duck,Fish" pale
                style Duck fill:red
                link Duck "https://example.com"
                """)
        else { return XCTFail("a painted class diagram is read") }
        XCTAssertEqual(diagram.boxes[0].style.fill, Flowchart.Colour(red: 1, green: 0, blue: 0))
        XCTAssertEqual(diagram.boxes[1].style.fill?.red, 238.0 / 255)
        XCTAssertEqual(diagram.boxes[0].style.stroke?.red, 51.0 / 255)
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

    /// `::icon(fa fa-book)` asks for a glyph out of a font nobody here has, and
    /// Mermaid draws nothing for it either. It belongs to the node above it.
    func testAMindmapIconIsReadAndDrawsNothing() throws {
        guard
            case .mindmap(let map)? = MermaidDiagram.parse(
                "mindmap\n  root\n    Origins\n      ::icon(fa fa-book)\n    Tools")
        else { return XCTFail("a mindmap with an icon is still a mindmap") }
        XCTAssertEqual(map.nodes.map(\.label), ["root", "Origins", "Tools"])
        XCTAssertEqual(map.nodes[0].children, [1, 2])
    }

    /// The two shapes a mindmap has that nothing else does, and its painting.
    func testAMindmapHasCloudsBangsAndPaintedNodes() throws {
        guard
            case .mindmap(let map)? = MermaidDiagram.parse(
                """
                mindmap
                  root((Markio))
                    puff)A cloud(
                    boom))A bang((
                    classDef pale fill:#eeeeee
                    class puff pale
                """)
        else { return XCTFail("a mindmap with clouds and bangs is read") }
        XCTAssertEqual(map.nodes.map(\.shape), [.circle, .cloud, .bang])
        XCTAssertEqual(map.nodes.map(\.label), ["Markio", "A cloud", "A bang"])
        XCTAssertEqual(map.nodes[1].style.fill?.red, 238.0 / 255)
        XCTAssertNil(map.nodes[2].style.fill)
    }

    func testWhatTheTreeDiagramsRefuse() {
        for source in [
            // A class of styles nobody defined, and one naming no node.
            "mindmap\n  root\n    class root missing",
            "mindmap\n  root\n    classDef pale fill:#eee\n    class nobody pale",
            // An icon with no node over it belongs to nothing.
            "mindmap\n  ::icon(fa fa-book)",
            "mindmap\n  root\n    a\n  second root",
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

    func testAJourneyScoresEachStepAndNamesWhoTookIt() throws {
        guard
            case .journey(let journey)? = MermaidDiagram.parse(
                """
                journey
                    title My working day
                    section Go to work
                      Make tea: 5: Me
                      Go upstairs: 3: Me, Cat
                    section Go home
                      Sit down: 5: Me
                """
            )
        else { return XCTFail("expected a journey") }
        XCTAssertEqual(journey.title, "My working day")
        XCTAssertEqual(journey.sections, ["Go to work", "Go home"])
        XCTAssertEqual(journey.tasks.map(\.name), ["Make tea", "Go upstairs", "Sit down"])
        XCTAssertEqual(journey.tasks.map(\.score), [5, 3, 5])
        XCTAssertEqual(journey.tasks.map(\.section), [0, 0, 1])
        XCTAssertEqual(journey.tasks[1].actors, ["Me", "Cat"])
    }

    func testAGanttCountsDaysFromItsFirstTask() throws {
        guard
            case .gantt(let chart)? = MermaidDiagram.parse(
                """
                gantt
                    title A release
                    dateFormat YYYY-MM-DD
                    section Writing
                        Draft  :done, a1, 2026-01-01, 10d
                        Review :active, a2, after a1, 5d
                    section Shipping
                        Build  :crit, a3, after a2, 1w
                        Live   :milestone, m1, after a3, 0d
                """
            )
        else { return XCTFail("expected a Gantt chart") }
        XCTAssertEqual(chart.sections, ["Writing", "Shipping"])
        XCTAssertEqual(chart.tasks.map(\.start), [0, 10, 15, 22])
        // A week is seven days, and a milestone has no length at all.
        XCTAssertEqual(chart.tasks.map(\.length), [10, 5, 7, 0])
        XCTAssertEqual(chart.tasks.map(\.done), [true, false, false, false])
        XCTAssertEqual(chart.tasks.map(\.critical), [false, false, true, false])
        XCTAssertTrue(chart.tasks[3].milestone)
        // The axis can print real dates because the source named one.
        XCTAssertEqual(chart.origin, GanttChart.day("2026-01-01"))
    }

    func testAGanttWithoutDatesJustCountsDays() throws {
        guard
            case .gantt(let chart)? = MermaidDiagram.parse(
                "gantt\n  Draft :3d\n  Review :2d"
            )
        else { return XCTFail("expected a Gantt chart") }
        // With no start written down, a task begins where the one above ended.
        XCTAssertEqual(chart.tasks.map(\.start), [0, 3])
        XCTAssertNil(chart.origin)
    }

    func testWhatTheChartsRefuse() {
        for source in [
            "journey\n  Make tea: 9: Me",
            // A day off nobody can name, and a tick as long as nothing.
            "gantt\n  excludes someday\n  Draft :3d",
            "gantt\n  includes weekends\n  Draft :3d",
            "gantt\n  tickInterval 1fortnight\n  Draft :3d",
            "gantt\n  displayMode roomy\n  Draft :3d",
            // A date that does not fit the format the chart declared.
            "gantt\n  dateFormat DD-MM-YYYY\n  Draft :a1, 2026-01-01",
            // A reference to a task that was never named.
            "gantt\n  Draft :after nothing, 3d",
            // A unit this does not know.
            "gantt\n  Draft :3y",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// A chart written around the working week, in a date format of its own.
    func testAGanttSkipsTheDaysNobodyWorks() throws {
        guard
            case .gantt(let chart)? = MermaidDiagram.parse(
                """
                gantt
                    dateFormat DD-MM-YYYY
                    axisFormat %d %b
                    tickInterval 1week
                    excludes weekends
                    todayMarker off
                    section Writing
                    Draft :02-01-2026, 3d
                """)
        else { return XCTFail("a gantt written around the working week is read") }
        // 2026-01-02 is a Friday, so three working days reach into Tuesday and
        // the bar spans five days of calendar.
        XCTAssertEqual(chart.tasks[0].start, 0)
        XCTAssertEqual(chart.tasks[0].length, 5)
        XCTAssertEqual(chart.excluded, [1, 2])
        XCTAssertFalse(chart.marksToday)
        XCTAssertEqual(chart.tickInterval?.unit, "week")
        XCTAssertEqual(
            GanttChart.date(
                GanttChart.day("02-01-2026", format: "DD-MM-YYYY")!,
                format: "%d %b"), "02 Jan")
    }

    /// `displayMode compact` puts tasks that do not overlap on one row.
    func testACompactGanttSharesItsRows() throws {
        let board = """
            gantt
                dateFormat YYYY-MM-DD
                section Work
                One :2026-01-01, 1d
                Two :2026-01-05, 1d
            """
        let roomy = try XCTUnwrap(
            DocumentRenderer.diagram(source: board, theme: Theme(isDark: false), width: 700))
        let packed = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: board.replacingOccurrences(
                    of: "    dateFormat", with: "    displayMode compact\n    dateFormat"),
                theme: Theme(isDark: false), width: 700))
        XCTAssertLessThan(packed.height, roomy.height)
    }

    func testTheChartsAreDrawnWhole() throws {
        for source in [
            "journey\n  title Day\n  section Work\n    Make tea: 5: Me\n    Do work: 1: Me",
            "gantt\n  title A release\n  section Writing\n    Draft :a1, 3d\n    Review :after a1, 2d",
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

    func testAQuadrantChartPlacesItsPointsInTheSquare() throws {
        guard
            case .quadrant(let chart)? = MermaidDiagram.parse(
                """
                quadrantChart
                    title Reach and engagement
                    x-axis Low Reach --> High Reach
                    y-axis Low Engagement --> High Engagement
                    quadrant-1 We should expand
                    quadrant-3 Re-evaluate
                    Campaign A: [0.3, 0.6]
                    Campaign B: [0.45, 0.23]
                """
            )
        else { return XCTFail("expected a quadrant chart") }
        XCTAssertEqual(chart.title, "Reach and engagement")
        XCTAssertEqual(chart.xAxis.low, "Low Reach")
        XCTAssertEqual(chart.xAxis.high, "High Reach")
        // Numbered clockwise from the top right, so 1 and 3 are opposite.
        XCTAssertEqual(chart.quadrants, ["We should expand", "", "Re-evaluate", ""])
        XCTAssertEqual(chart.points.map(\.label), ["Campaign A", "Campaign B"])
        XCTAssertEqual(chart.points[0].x, 0.3)
        XCTAssertEqual(chart.points[0].y, 0.6)
    }

    func testAnXYChartTakesItsRangeFromTheAxisOrTheData() throws {
        guard
            case .xy(let named)? = MermaidDiagram.parse(
                """
                xychart-beta
                    title "Sales revenue"
                    x-axis [jan, feb, mar]
                    y-axis "Revenue" 4000 --> 11000
                    bar [5000, 6000, 7500]
                    line [4500, 6500, 7000]
                """
            )
        else { return XCTFail("expected an xy chart") }
        XCTAssertEqual(named.title, "Sales revenue")
        XCTAssertEqual(named.categories, ["jan", "feb", "mar"])
        XCTAssertEqual(named.yTitle, "Revenue")
        XCTAssertEqual(named.yRange?.low, 4000)
        XCTAssertEqual(named.yRange?.high, 11000)
        XCTAssertEqual(named.series.map(\.isBar), [true, false])

        guard case .xy(let bare)? = MermaidDiagram.parse("xychart-beta\n  bar [1, 2, 3]") else {
            return XCTFail("expected an xy chart")
        }
        // With no categories written down the bars are simply numbered.
        XCTAssertEqual(bare.categories, ["1", "2", "3"])
        XCTAssertNil(bare.yRange)
    }

    func testAGitGraphPutsEachBranchInItsOwnLane() throws {
        guard
            case .git(let graph)? = MermaidDiagram.parse(
                """
                gitGraph
                   commit id: "start"
                   commit
                   branch develop
                   checkout develop
                   commit
                   checkout main
                   merge develop
                   commit tag: "v1.0" type: HIGHLIGHT
                """
            )
        else { return XCTFail("expected a git graph") }
        XCTAssertEqual(graph.branches, ["main", "develop"])
        XCTAssertEqual(graph.commits.map(\.branch), [0, 0, 1, 0, 0])
        // Every commit takes the next column, merges included.
        XCTAssertEqual(graph.commits.map(\.column), [0, 1, 2, 3, 4])
        XCTAssertEqual(graph.commits[0].label, "start")
        XCTAssertEqual(graph.commits[3].merges, 2)
        XCTAssertEqual(graph.commits[4].tag, "v1.0")
        XCTAssertEqual(graph.commits[4].kind, .highlighted)
    }

    func testACommitSaysWhichKindItIs() throws {
        guard
            case .git(let graph)? = MermaidDiagram.parse(
                """
                gitGraph
                   commit
                   commit id: "undo" type: REVERSE
                   commit id: "plain" type: NORMAL
                """
            )
        else { return XCTFail("expected a git graph") }
        XCTAssertEqual(graph.commits.map(\.kind), [.normal, .reverse, .normal])
        // A kind nobody draws is refused rather than read as an ordinary commit.
        XCTAssertNil(MermaidDiagram.parse("gitGraph\n   commit type: CHERRY_PICK"))
    }

    /// Mermaid keeps drawing when a series runs past the names on the axis or
    /// past its neighbour, so these are charts and not mistakes.
    func testASeriesMayRunPastItsAxisAndItsNeighbour() throws {
        let named = "xychart-beta\n  x-axis [a, b]\n  bar [1, 2, 3]"
        guard case .xy(let long)? = MermaidDiagram.parse(named) else {
            return XCTFail("a third bar stands on an unnamed place")
        }
        XCTAssertEqual(long.categories, ["a", "b", ""])
        XCTAssertNotNil(
            DocumentRenderer.diagram(source: named, theme: Theme(isDark: false), width: 700))

        let uneven = "xychart-beta\n  bar [1, 2]\n  line [1, 2, 3]"
        guard case .xy(let mixed)? = MermaidDiagram.parse(uneven) else {
            return XCTFail("a short series stops where its numbers do")
        }
        XCTAssertEqual(mixed.categories, ["1", "2", "3"])
        XCTAssertNotNil(
            DocumentRenderer.diagram(source: uneven, theme: Theme(isDark: false), width: 700))
    }

    func testWhatThePlotsRefuse() {
        for source in [
            // A point outside the square, and one with no coordinates at all.
            "quadrantChart\n  A: [1.4, 0.2]",
            "quadrantChart\n  A: [0.2]",
            // Series that do not line up with the names under them.
            "xychart-beta\n  x-axis [a, b]",
            // A cherry-pick of a commit nobody made, and one of a commit on
            // the branch it is already standing on.
            "gitGraph\n  commit\n  cherry-pick id: \"x\"",
            "gitGraph\n  commit id: \"A\"\n  cherry-pick id: \"A\"",
            "gitGraph\n  commit\n  merge nothing",
            "gitGraph\n  commit\n  checkout nothing",
            // A direction nobody knows.
            "gitGraph XY:\n  commit",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testThePlotsAreDrawnWhole() throws {
        for source in [
            "quadrantChart\n  quadrant-1 Expand\n  A: [0.3, 0.6]\n  B: [0.8, 0.2]",
            "xychart-beta\n  x-axis [a, b, c]\n  bar [1, 2, 3]",
            "gitGraph\n  commit\n  branch dev\n  checkout dev\n  commit\n  checkout main\n  merge dev",
        ] {
            let document = Document(text: "```mermaid\n\(source)\n```")
            let layout = DocumentLayout(
                document: document, theme: Theme(isDark: false), columnWidth: 520)
            let box = try XCTUnwrap(layout.box(at: 0))
            XCTAssertTrue(box.segments.isEmpty, source)
            XCTAssertGreaterThan(box.decorations.count, 8, source)
            XCTAssertGreaterThan(box.height, 60, source)
        }
    }

    func testAPacketIsReadAsAContiguousRunOfBits() throws {
        guard
            case .packet(let packet)? = MermaidDiagram.parse(
                """
                packet-beta
                title UDP header
                0-15: "Source port"
                16-31: "Destination port"
                +16: "Length"
                48: "One flag"
                """
            )
        else { return XCTFail("expected a packet diagram") }
        XCTAssertEqual(packet.title, "UDP header")
        XCTAssertEqual(
            packet.fields.map(\.label),
            [
                "Source port", "Destination port", "Length", "One flag",
            ])
        // `+16` is sixteen more bits after the field above it.
        XCTAssertEqual(packet.fields.map(\.first), [0, 16, 32, 48])
        XCTAssertEqual(packet.fields.map(\.last), [15, 31, 47, 48])
    }

    func testAKanbanBoardTakesItsColumnsFromTheIndentation() throws {
        guard
            case .kanban(let board)? = MermaidDiagram.parse(
                """
                kanban
                  Todo
                    t1[Read the bytes]
                    t2[Scan the blocks]@{ assigned: 'korchasa', priority: 'High' }
                  Done
                    t3[Ship]
                """
            )
        else { return XCTFail("expected a kanban board") }
        XCTAssertEqual(board.columns.map(\.title), ["Todo", "Done"])
        XCTAssertEqual(board.columns[0].cards.map(\.label), ["Read the bytes", "Scan the blocks"])
        XCTAssertEqual(board.columns[0].cards[1].details, ["korchasa"])
        XCTAssertEqual(board.columns[0].cards[1].priority, "High")
        XCTAssertEqual(board.columns[1].cards.map(\.label), ["Ship"])
    }

    func testARequirementDiagramReadsIntoTheSameBoxes() throws {
        guard
            case .boxes(let diagram)? = MermaidDiagram.parse(
                """
                requirementDiagram
                requirement speed_req {
                id: 1
                text: opens fast.
                risk: high
                }
                element bench {
                type: measurement
                }
                bench - verifies -> speed_req
                """
            )
        else { return XCTFail("expected a requirement diagram") }
        XCTAssertEqual(diagram.boxes.map(\.name), ["speed_req", "bench"])
        XCTAssertEqual(diagram.boxes.map(\.stereotype), ["requirement", "element"])
        // The keywords are written as words: `id` is an ID, `high` a risk that
        // starts a sentence.
        XCTAssertEqual(
            diagram.boxes[0].compartments[0], ["ID: 1", "Text: opens fast.", "Risk: High"])
        XCTAssertEqual(diagram.links.count, 1)
        XCTAssertEqual(diagram.links[0].label, "verifies")
        // The arrow runs from the thing that verifies to the thing verified.
        XCTAssertEqual(diagram.links[0].from, 1)
        XCTAssertEqual(diagram.links[0].to, 0)
    }

    func testWhatTheBoardsRefuse() {
        for source in [
            // Two fields over one bit.
            "packet-beta\n0-15: \"A\"\n8-31: \"B\"",
            "packet-beta\n0-15",
            // Metadata this does not draw, and a card with no column above it.
            "kanban\n  Todo\n    t1[A]@{ colour: 'red' }",
            "kanban\n    t1[A]\n  Todo",
            // A relation this does not know, and an unclosed block.
            "requirementDiagram\n requirement a {\n id: 1\n }\n a - invents -> a",
            "requirementDiagram\n requirement a {\n id: 1",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// `gitGraph TB:` turns the lanes down the page: the same graph, drawn the
    /// other way round.
    func testAGitGraphTurnsItsLanesDownThePage() throws {
        let source = "gitGraph TB:\n  commit\n  branch feature\n  commit\n  checkout main\n  commit"
        guard case .git(let graph)? = MermaidDiagram.parse(source) else {
            return XCTFail("a turned git graph is still a git graph")
        }
        XCTAssertTrue(graph.vertical)
        let turned = try XCTUnwrap(
            DocumentRenderer.diagram(source: source, theme: Theme(isDark: false), width: 700))
        let across = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: source.replacingOccurrences(of: "gitGraph TB:", with: "gitGraph"),
                theme: Theme(isDark: false), width: 700))
        XCTAssertGreaterThan(turned.height, across.height)
        XCTAssertLessThan(turned.width, across.width)
    }

    /// A cherry-pick is the same work said twice, on a dotted line.
    func testAGitGraphCherryPicksAcrossBranches() throws {
        guard
            case .git(let graph)? = MermaidDiagram.parse(
                """
                gitGraph
                    commit id: "A"
                    branch feature
                    commit id: "B"
                    checkout main
                    cherry-pick id: "B"
                """)
        else { return XCTFail("a cherry-pick is read") }
        XCTAssertEqual(graph.commits.map(\.label), ["A", "B", "B"])
        XCTAssertEqual(graph.commits[2].picks, 1)
        XCTAssertEqual(graph.commits[2].branch, 0)
        XCTAssertNil(graph.commits[2].merges)
    }

    /// A gap between fields is a run of bits the author left unspoken.
    func testAPacketDrawsTheBitsNobodyNamed() throws {
        guard
            case .packet(let packet)? = MermaidDiagram.parse(
                "packet-beta\n0-15: \"A\"\n20-31: \"B\"")
        else { return XCTFail("a packet with a gap is read") }
        XCTAssertEqual(packet.fields.map(\.label), ["A", "", "B"])
        XCTAssertEqual(packet.fields.map(\.first), [0, 16, 20])
        XCTAssertEqual(packet.fields.map(\.last), [15, 19, 31])
    }

    func testTheBoardsAreDrawnWhole() throws {
        for source in [
            "packet-beta\n0-15: \"Source\"\n16-31: \"Target\"",
            "kanban\n  Todo\n    t1[Read]\n  Done\n    t2[Ship]",
            "requirementDiagram\nrequirement a {\nid: 1\n}\nelement b {\ntype: test\n}\nb - verifies -> a",
        ] {
            let document = Document(text: "```mermaid\n\(source)\n```")
            let layout = DocumentLayout(
                document: document, theme: Theme(isDark: false), columnWidth: 520)
            let box = try XCTUnwrap(layout.box(at: 0))
            XCTAssertTrue(box.segments.isEmpty, source)
            XCTAssertGreaterThan(box.decorations.count, 6, source)
            XCTAssertGreaterThan(box.height, 50, source)
        }
    }

    func testASankeyReadsItsFlowsAsCsv() throws {
        guard
            case .sankey(let diagram)? = MermaidDiagram.parse(
                """
                sankey-beta
                Bytes,Scan,100
                Scan,Parse,60
                Scan,"Skipped, unread",40
                """
            )
        else { return XCTFail("expected a Sankey diagram") }
        XCTAssertEqual(diagram.nodes, ["Bytes", "Scan", "Parse", "Skipped, unread"])
        XCTAssertEqual(diagram.flows.map(\.value), [100, 60, 40])
        XCTAssertEqual(diagram.flows.map { [$0.from, $0.to] }, [[0, 1], [1, 2], [1, 3]])
    }

    func testATreemapSumsItsBranchesFromItsLeaves() throws {
        guard
            case .treemap(let map)? = MermaidDiagram.parse(
                """
                treemap-beta
                "Parser"
                    "Blocks": 42
                    "Inline": 28
                "Renderer"
                    "Typesetting": 30
                """
            )
        else { return XCTFail("expected a treemap") }
        // Several roots are given a parent that is never itself drawn.
        XCTAssertEqual(map.nodes[0].label, "")
        XCTAssertEqual(map.nodes[0].value, 100)
        XCTAssertEqual(
            map.nodes.map(\.label), ["", "Parser", "Blocks", "Inline", "Renderer", "Typesetting"])
        XCTAssertEqual(map.nodes[1].value, 70)
        XCTAssertEqual(map.nodes[4].value, 30)
    }

    /// A branch of a treemap may carry a number of its own, and what it holds
    /// is the truer figure — which is the one Mermaid draws.
    func testABranchTakesTheSumOfWhatItHolds() throws {
        guard
            case .treemap(let map)? = MermaidDiagram.parse(
                "treemap-beta\n\"A\": 5\n    \"B\": 2")
        else { return XCTFail("a branch with a number is still a branch") }
        XCTAssertEqual(map.nodes[0].value, 2)
        XCTAssertEqual(map.nodes[0].children, [1])
    }

    func testWhatTheFlowsRefuse() {
        for source in [
            // A flow back to where it came from makes the ranks meaningless.
            "sankey-beta\nA,B,1\nB,A,1",
            "sankey-beta\nA,A,1",
            "sankey-beta\nA,B",
            "sankey-beta\nA,B,none",
            "sankey-beta\nA,B,0",
            // A node cannot both carry a number and hold other nodes.
            "treemap-beta\n\"A\"\n    \"B\": none",
            "treemap-beta\n\"A\"\n    \"B\": 0",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testTheFlowsAreDrawnWhole() throws {
        for source in [
            "sankey-beta\nA,B,10\nB,C,6\nB,D,4",
            "treemap-beta\n\"A\"\n    \"B\": 5\n    \"C\": 3",
        ] {
            let document = Document(text: "```mermaid\n\(source)\n```")
            let layout = DocumentLayout(
                document: document, theme: Theme(isDark: false), columnWidth: 520)
            let box = try XCTUnwrap(layout.box(at: 0))
            XCTAssertTrue(box.segments.isEmpty, source)
            XCTAssertGreaterThan(box.decorations.count, 6, source)
            XCTAssertGreaterThan(box.height, 50, source)
        }
    }

    func testAC4DiagramBecomesAFlowchartWithC4Shapes() throws {
        // The `title` line names the picture, so what comes back is a named
        // diagram with the flowchart inside it.
        guard
            case .titled("Orders", .flowchart(let chart))? = MermaidDiagram.parse(
                """
                C4Context
                  title Orders
                  Person(customer, "Customer", "Buys things")
                  System_Boundary(shop, "Shop") {
                    System(web, "Storefront")
                    SystemDb(db, "Order store")
                    SystemQueue(queue, "Dispatch")
                  }
                  System_Ext(bank, "Payments")
                  Rel(customer, web, "Orders")
                  Rel_Back(db, web, "Reads")
                  BiRel(web, bank, "Settles")
                """
            )
        else { return XCTFail("expected a named C4 diagram") }
        XCTAssertEqual(chart.nodes.map(\.id), ["customer", "web", "db", "queue", "bank"])
        XCTAssertEqual(
            chart.nodes.map(\.shape), [.stadium, .rectangle, .cylinder, .subroutine, .rectangle])
        // The kind, the name and what it does are three lines of one label.
        XCTAssertEqual(chart.nodes[0].label, "«Person»<br/>Customer<br/>Buys things")
        // Only what is outside the system under discussion is given a fill.
        XCTAssertNil(chart.nodes[1].style.fill)
        XCTAssertNotNil(chart.nodes[4].style.fill)
        XCTAssertEqual(chart.groups.map(\.title), ["Shop"])
        XCTAssertEqual(chart.groups[0].members, [1, 2, 3])
        // `Rel_Back` points the other way, and `BiRel` is two arrows.
        XCTAssertEqual(chart.edges.count, 4)
        XCTAssertEqual(chart.edges[1].from, .node(1))
        XCTAssertEqual(chart.edges[1].to, .node(2))
        XCTAssertEqual(chart.edges[2].to, .node(4))
        XCTAssertEqual(chart.edges[3].to, .node(1))
    }

    func testAnArchitectureTakesItsGridFromTheSidesItsEdgesUse() throws {
        guard
            case .architecture(let diagram)? = MermaidDiagram.parse(
                """
                architecture-beta
                  group api(cloud)[API]
                  service db(database)[Database] in api
                  service disk1(disk)[Storage] in api
                  service server(server)[Server] in api
                  service gateway(internet)[Gateway]
                  db:L -- R:server
                  disk1:T -- B:server
                  gateway:B --> T:server
                """
            )
        else { return XCTFail("expected an architecture diagram") }
        XCTAssertEqual(diagram.groups.map(\.label), ["API"])
        XCTAssertEqual(diagram.services.map(\.label), ["Database", "Storage", "Server", "Gateway"])
        XCTAssertEqual(diagram.services.map(\.icon), [.database, .disk, .server, .internet])
        XCTAssertEqual(diagram.services.map(\.group), [0, 0, 0, nil])
        // The server is left of the database, above the storage and below the
        // gateway, which is exactly what the three edges say.
        let cells = diagram.services.map { [$0.column, $0.row] }
        XCTAssertEqual(cells, [[1, 1], [0, 2], [0, 1], [0, 0]])
        XCTAssertTrue(diagram.edges[2].toArrow)
        XCTAssertFalse(diagram.edges[0].toArrow)
    }

    /// Mermaid draws a question mark for any icon name it cannot resolve, and
    /// a misspelt name is no different to it than one from a pack nobody
    /// registered.
    func testAnIconNobodyKnowsIsDrawnAsAQuestion() throws {
        guard
            case .architecture(let diagram)? = MermaidDiagram.parse(
                "architecture-beta\n  service a(wobble)[A]\n  service b(server)[B]\n  a:R -- L:b")
        else { return XCTFail("an unknown icon is still a service") }
        XCTAssertEqual(diagram.services[0].icon, .unknown)
        XCTAssertEqual(diagram.services[1].icon, .server)
    }

    func testWhatC4AndArchitectureRefuse() {
        for source in [
            // An element with no name, a boundary left open, and a restyling of
            // a diagram that is already drawn.
            "C4Context\n  Person(a)",
            "C4Context\n  System_Boundary(b, \"B\") {\n  System(a, \"A\")",
            // A restyling of something nobody wrote, a colour that is no colour,
            // and a setting nobody knows.
            "C4Context\n  System(a, \"A\")\n  UpdateElementStyle(b, $bgColor=\"red\")",
            "C4Context\n  System(a, \"A\")\n  UpdateElementStyle(a, $bgColor=\"chartruse\")",
            "C4Context\n  System(a, \"A\")\n  UpdateElementStyle(a, $wobble=\"3\")",
            "C4Context\n  Nonsense(a, \"A\")",
            // A group written inside one nobody declared.
            "architecture-beta\n  group two(cloud)[Two] in one\n  service a(server)[A] in two",
            // A stranger standing inside a group's block would look like a member.
            "architecture-beta\n  group g(cloud)[G]\n  service a(server)[A] in g\n"
                + "  service b(server)[B] in g\n  service c(server)[C]\n"
                + "  a:R -- L:c\n  c:R -- L:b",
            "architecture-beta\n  service a(server)[A]\n  a:X -- L:a",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// A group inside a group, an icon out of a pack, and two services sent to
    /// one cell — which the second walks on from.
    func testAnArchitectureNestsGroupsAndMakesRoom() throws {
        guard
            case .architecture(let diagram)? = MermaidDiagram.parse(
                """
                architecture-beta
                  group one(cloud)[One]
                  group two(cloud)[Two] in one
                  service a(server)[A] in two
                  service b(logos:aws)[B] in two
                  service c(server)[C] in two
                  a:R -- L:b
                  a:R -- L:c
                """)
        else { return XCTFail("an architecture with nested groups is read") }
        XCTAssertEqual(diagram.groups.map(\.parent), [nil, 0])
        XCTAssertEqual(diagram.depth(of: 1), 1)
        // The outer group holds everything the inner one holds.
        XCTAssertEqual(diagram.members(of: 0), [0, 1, 2])
        XCTAssertEqual(diagram.services[1].icon, .unknown)
        // B took the cell to A's right, so C walked one further along.
        XCTAssertEqual(diagram.services.map { [$0.column, $0.row] }, [[0, 0], [1, 0], [2, 0]])
    }

    /// The lines that repaint a C4 diagram after it has been written.
    func testAC4DiagramIsRepaintedByItsUpdateLines() throws {
        guard
            case .flowchart(let chart)? = MermaidDiagram.parse(
                """
                C4Context
                  Enterprise_Boundary(b0, "Bank") {
                    System_Boundary(b1, "Core") {
                      System(a, "A")
                    }
                  }
                  System(c, "C")
                  Rel(a, c, "Calls")
                  UpdateElementStyle(a, $bgColor="blue", $fontColor="white")
                  UpdateBoundaryStyle(b0, $borderColor="red")
                  UpdateRelStyle(a, c, $textColor="red", $offsetY="-40")
                  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
                """)
        else { return XCTFail("a C4 diagram is read into a flowchart") }
        // A boundary inside a boundary is a frame inside a frame.
        XCTAssertEqual(chart.groups.map(\.title), ["Bank", "Core"])
        XCTAssertEqual(chart.groups.map(\.parent), [nil, 0])
        XCTAssertEqual(chart.nodes[0].style.fill, Flowchart.Colour(red: 0, green: 0, blue: 1))
        XCTAssertEqual(chart.nodes[0].style.text, Flowchart.Colour(red: 1, green: 1, blue: 1))
        XCTAssertEqual(chart.groups[0].style.stroke, Flowchart.Colour(red: 1, green: 0, blue: 0))
        XCTAssertEqual(chart.edges[0].style.text, Flowchart.Colour(red: 1, green: 0, blue: 0))
    }

    func testC4AndArchitectureAreDrawnWhole() throws {
        for source in [
            "C4Context\n  Person(a, \"Someone\")\n  System(b, \"Thing\")\n  Rel(a, b, \"Uses\")",
            "architecture-beta\n  group g(cloud)[Cloud]\n  service a(server)[App] in g\n"
                + "  service d(database)[Data] in g\n  a:R -- L:d",
        ] {
            let document = Document(text: "```mermaid\n\(source)\n```")
            let layout = DocumentLayout(
                document: document, theme: Theme(isDark: false), columnWidth: 520)
            let box = try XCTUnwrap(layout.box(at: 0))
            XCTAssertTrue(box.segments.isEmpty, source)
            XCTAssertGreaterThan(box.decorations.count, 6, source)
            XCTAssertGreaterThan(box.height, 50, source)
        }
    }

    func testARadarTakesOneValuePerAxisPerCurve() throws {
        guard
            case .radar(let chart)? = MermaidDiagram.parse(
                """
                radar-beta
                  title Trade-offs
                  axis speed["Speed"], memory["Memory"], reach
                  curve native["Native"]{9, 8, 4}
                  curve web{3, 2, 9}
                  max 10
                  ticks 4
                  graticule polygon
                """
            )
        else { return XCTFail("expected a radar chart") }
        XCTAssertEqual(chart.title, "Trade-offs")
        // An axis with no words of its own is named by its identifier.
        XCTAssertEqual(chart.axes, ["Speed", "Memory", "reach"])
        XCTAssertEqual(chart.curves.map(\.label), ["Native", "web"])
        XCTAssertEqual(chart.curves[1].values, [3, 2, 9])
        XCTAssertEqual(chart.high, 10)
        XCTAssertEqual(chart.ticks, 4)
        XCTAssertTrue(chart.polygon)
        // With no `max`, the outer ring is the largest value written.
        guard
            case .radar(let open)? = MermaidDiagram.parse(
                "radar-beta\n  axis a, b, c\n  curve one{1, 5, 3}")
        else { return XCTFail("expected a radar chart") }
        XCTAssertEqual(open.high, 5)
    }

    func testABlockDiagramFillsItsGridAndWraps() throws {
        guard
            case .blocks(let diagram)? = MermaidDiagram.parse(
                """
                block-beta
                  columns 3
                  doc["Whole document"]:3
                  bytes["Bytes"] blocks["Blocks"] inline("Inline")
                  space boxes["Boxes"]:2
                  blocks --> boxes
                """
            )
        else { return XCTFail("expected a block diagram") }
        XCTAssertEqual(diagram.columns, 3)
        XCTAssertEqual(
            diagram.chart.nodes.map(\.id), ["doc", "bytes", "blocks", "inline", "boxes"])
        XCTAssertEqual(diagram.chart.nodes[3].shape, .rounded)
        XCTAssertEqual(diagram.chart.nodes[0].label, "Whole document")
        XCTAssertEqual(diagram.cells.map(\.span), [3, 1, 1, 1, 1, 2])
        // The blank cell holds a place and names nothing.
        XCTAssertNil(diagram.cells[4].node)
        XCTAssertEqual(diagram.chart.edges.count, 1)
        XCTAssertEqual(diagram.chart.edges[0].from, .node(2))
        XCTAssertEqual(diagram.chart.edges[0].to, .node(4))
    }

    func testZenUmlKeepsTrackOfWhoIsCalling() throws {
        let diagram = try XCTUnwrap(
            sequence(
                """
                zenuml
                  title Opening
                  @Actor Reader
                  @Starter(Reader)
                  Window.open(path) {
                    Cache.lookup(path)
                    if (miss) {
                      Cache.fill()
                    } else {
                      Cache.hit()
                    }
                    return shown
                  }
                  Reader->Window: scrolls
                """
            )
        )
        XCTAssertEqual(diagram.title, "Opening")
        XCTAssertEqual(diagram.participants.map(\.id), ["Reader", "Window", "Cache"])
        let messages = diagram.messages
        XCTAssertEqual(
            messages.map(\.text),
            [
                "open(path)", "lookup(path)", "fill()", "hit()", "shown", "scrolls",
            ])
        // Inside the braces the window is the one calling, and the reply goes
        // back to whoever was waiting.
        XCTAssertEqual(messages[1].from, 1)
        XCTAssertEqual(messages[1].to, 2)
        XCTAssertEqual(messages[4].from, 1)
        XCTAssertEqual(messages[4].to, 0)
        XCTAssertTrue(messages[4].dashed)
        // The braces after a call put a bar on the callee, not a frame round the
        // calls inside, so the alternative sits at the top level beside them.
        guard case .block(let block) = diagram.items[2] else { return XCTFail("expected a block") }
        XCTAssertEqual(block.kind, "alt")
        XCTAssertEqual(block.sections.map(\.title), ["miss", ""])
    }

    /// Two axes make a line rather than a shape, and zero rings leave a bare
    /// web — Mermaid draws both, so the drawing takes what it is given.
    func testARadarDrawsTwoAxesAndAWebWithNoRings() throws {
        XCTAssertNotNil(
            DocumentRenderer.diagram(
                source: "radar-beta\n  axis a, b\n  curve one{1, 2}",
                theme: Theme(isDark: false), width: 700))
        let bare = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "radar-beta\n  axis a, b, c\n  curve one{1, 2, 3}\n  ticks 0",
                theme: Theme(isDark: false), width: 700))
        let ringed = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "radar-beta\n  axis a, b, c\n  curve one{1, 2, 3}",
                theme: Theme(isDark: false), width: 700))
        XCTAssertEqual(bare.width, ringed.width)
    }

    /// A block arrow may name a box that no row wrote out, and Mermaid draws
    /// that box rather than throwing the diagram away.
    func testABlockArrowDeclaresTheBoxItNames() throws {
        guard
            case .blocks(let diagram)? = MermaidDiagram.parse(
                "block-beta\n  columns 2\n  a b\n  a --> nothing")
        else { return XCTFail("an arrow names a box into being") }
        XCTAssertEqual(diagram.chart.nodes.map(\.id), ["a", "b", "nothing"])
        XCTAssertEqual(diagram.cells.count, 3)
    }

    func testWhatRadarBlocksAndZenUmlRefuse() {
        for source in [
            // A chart with no curve at all has nothing on it, and a web can
            // only be drawn round or many-sided.
            "radar-beta\n  axis a, b, c",
            "radar-beta\n  axis a, b, c\n  curve one{1, 2, 3}\n  graticule star",
            // A block left open, one closed twice, and one named twice.
            "block-beta\n  columns 2\n  block:group\n    a b",
            "block-beta\n  columns 2\n  a b\n  end",
            "block-beta\n  columns 2\n  block:g\n    a\n  end\n  block:g\n    b\n  end",
            "block-beta\n  columns 2\n  a:0 b",
            // A reply with nobody waiting, a call left open and one closed
            // twice.
            "zenuml\n  @Starter(A)\n  return done",
            "zenuml\n  @Starter(A)\n  B.open() {",
            "zenuml\n  @Starter(A)\n  B.open()\n  }",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    /// A curve short of a value is dropped and the axes are still drawn, which
    /// is what Mermaid itself does with one.
    func testARadarDropsACurveThatCannotClose() throws {
        guard
            case .radar(let chart)? = MermaidDiagram.parse(
                """
                radar-beta
                  axis a, b, c
                  curve short{1, 2}
                  curve whole{1, 2, 3}
                """)
        else { return XCTFail("a radar with a short curve is still a radar") }
        XCTAssertEqual(chart.curves.map(\.label), ["whole"])
        XCTAssertEqual(chart.axes.count, 3)
    }

    /// A call nobody made comes from the nameless figure Mermaid draws, and a
    /// `try` block is a frame with arms like any other.
    func testAZenUmlCallNeedsNoCallerAndMayTry() throws {
        guard
            case .sequence(let diagram)? = MermaidDiagram.parse(
                """
                zenuml
                  Window.open() {
                    try {
                      Store.read()
                    } catch (e) {
                      Log.write()
                    } finally {
                      Store.close()
                    }
                  }
                """)
        else { return XCTFail("a ZenUML call with no caller is still a diagram") }
        XCTAssertEqual(diagram.participants[0].label, "")
        XCTAssertTrue(diagram.participants[0].isActor)
        XCTAssertEqual(diagram.participants.map(\.id).dropFirst(), ["Window", "Store", "Log"])
        guard case .block(let block) = diagram.items.dropFirst().first else {
            return XCTFail("the try is a block")
        }
        XCTAssertEqual(block.kind, "try")
        XCTAssertEqual(block.sections.map(\.title), ["", "catch e", "finally"])
    }

    /// `block:ID … end` is a grid inside a cell of the grid, and an edge may
    /// name it. `blockArrowId<[…]>(down)` is a fat arrow with words in it.
    func testABlockHoldsABlockAndAFatArrow() throws {
        guard
            case .blocks(let diagram)? = MermaidDiagram.parse(
                """
                block-beta
                columns 1
                  wide<["go"]>(down)
                  block:ID
                    A
                    B["In the middle"]
                  end
                  D
                  ID --> D
                """)
        else { return XCTFail("a block diagram with a block inside it is still one") }
        XCTAssertEqual(diagram.blocks.map(\.id), ["ID"])
        XCTAssertEqual(diagram.blocks[0].cells.compactMap(\.node).count, 2)
        // The arrow, the framed block and `D` are the diagram's own three cells.
        XCTAssertEqual(diagram.cells.count, 3)
        XCTAssertEqual(diagram.chart.nodes[0].shape, .arrowDown)
        XCTAssertEqual(diagram.chart.nodes[0].label, "go")
        // The edge ends on the frame, not on any box inside it.
        XCTAssertEqual(diagram.chart.edges[0].from, .frame(0))
    }

    func testRadarBlocksAndZenUmlAreDrawnWhole() throws {
        for source in [
            "radar-beta\n  axis a, b, c\n  curve one{1, 5, 3}\n  curve two{4, 2, 5}",
            "block-beta\n  columns 2\n  a[\"One\"] b[\"Two\"]\n  c[\"Three\"]:2\n  a --> c",
            "zenuml\n  @Starter(A)\n  B.open()\n  A->B: again",
        ] {
            let document = Document(text: "```mermaid\n\(source)\n```")
            let layout = DocumentLayout(
                document: document, theme: Theme(isDark: false), columnWidth: 520)
            let box = try XCTUnwrap(layout.box(at: 0))
            XCTAssertTrue(box.segments.isEmpty, source)
            XCTAssertGreaterThan(box.decorations.count, 6, source)
            XCTAssertGreaterThan(box.height, 50, source)
        }
    }

    /// A theme is a picture drawn in the colours its author asked for, not in
    /// the reader's.
    func testAPreamblePaintsTheDiagramInItsOwnTheme() throws {
        let source = """
            ---
            config:
              theme: forest
            ---
            pie
              "A" : 1
              "B" : 2
            """
        guard case .themed(let name, let inner)? = MermaidDiagram.parse(source) else {
            return XCTFail("the preamble's theme did not reach the diagram")
        }
        XCTAssertEqual(name, "forest")
        guard case .pie = inner else { return XCTFail("the diagram under it is still a pie") }
        // The picture is the same size and a different set of colours.
        let painted = try XCTUnwrap(
            DocumentRenderer.diagram(source: source, theme: Theme(isDark: false), width: 520))
        let plain = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "pie\n  \"A\" : 1\n  \"B\" : 2", theme: Theme(isDark: false),
                width: 520))
        XCTAssertEqual(painted.width, plain.width)
        XCTAssertEqual(painted.height, plain.height)
        XCTAssertNotEqual(
            Theme(isDark: false).mermaidThemed("forest")?.diagramWheel.first,
            Theme(isDark: false).diagramWheel.first)
        XCTAssertNil(Theme(isDark: false).mermaidThemed("nightfall"))

        // The same thing said on a directive line, which looks like a comment
        // and is not one.
        guard
            case .themed(let directed, _)? = MermaidDiagram.parse(
                "%%{init: {'theme':'dark'}}%%\npie\n  \"A\" : 1")
        else { return XCTFail("the init directive did not reach the diagram") }
        XCTAssertEqual(directed, "dark")
        // A directive that says anything else changes how Mermaid draws rather
        // than what it draws, so the fence stays source.
        XCTAssertNil(MermaidDiagram.parse("%%{init: {'theme':'nightfall'}}%%\npie\n  \"A\" : 1"))
        XCTAssertNil(
            MermaidDiagram.parse("%%{init: {'flowchart':{'curve':'basis'}}}%%\nflowchart TD\n A"))
        // A plain comment is still a comment.
        XCTAssertNotNil(MermaidDiagram.parse("%% a note to the reader\npie\n  \"A\" : 1"))
    }

    func testAPreambleNamesTheDiagram() throws {
        let source = """
            ---
            title: "Order example"
            ---
            erDiagram
                CUSTOMER ||--o{ ORDER : places
            """
        guard case .titled(let title, let inner) = MermaidDiagram.parse(source) else {
            return XCTFail("the preamble's title did not reach the diagram")
        }
        // The quotes belong to YAML, not to the name.
        XCTAssertEqual(title, "Order example")
        guard case .boxes = inner else {
            return XCTFail("the diagram under the title is still an entity diagram")
        }
        // A name is drawn above the picture, so the block grows by a line.
        let named = DocumentLayout(
            document: Document(text: "```mermaid\n\(source)\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        let bare = DocumentLayout(
            document: Document(
                text: "```mermaid\nerDiagram\n    CUSTOMER ||--o{ ORDER : places\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        let withTitle = try XCTUnwrap(named.box(at: 0))
        let without = try XCTUnwrap(bare.box(at: 0))
        XCTAssertGreaterThan(withTitle.height, without.height)
        XCTAssertEqual(withTitle.decorations.count, without.decorations.count + 1)
    }

    /// The one `config` setting a preamble may carry: where a board's tickets
    /// live, which turns every ticket id into a link.
    func testAKanbanPreambleSaysWhereItsTicketsLive() throws {
        let source = """
            ---
            config:
              kanban:
                ticketBaseUrl: 'https://example.com/browse/#TICKET#'
            ---
            kanban
              todo[Todo]
                id4[Write it]@{ ticket: MC-1, assigned: 'kim' }
            """
        guard case .kanban(let board)? = MermaidDiagram.parse(source) else {
            return XCTFail("a board with a ticket url is still a board")
        }
        XCTAssertEqual(board.ticketBaseUrl, "https://example.com/browse/#TICKET#")
        XCTAssertEqual(board.columns[0].cards[0].ticket, "MC-1")
        XCTAssertEqual(board.columns[0].cards[0].details, ["kim"])
    }

    /// A preamble may carry a width, a title nobody filled in, or a key meant
    /// for another kind of diagram; Mermaid draws all three.
    func testAPreambleWidensAColumnAndLeavesSpareKeysAlone() throws {
        guard
            case .kanban(let wide)? = MermaidDiagram.parse(
                "---\nconfig:\n  kanban:\n    sectionWidth: 200\n---\nkanban\n  a[A]")
        else { return XCTFail("a width is a width") }
        XCTAssertEqual(wide.columnWidth, 200)

        let board = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "---\nconfig:\n  kanban:\n    sectionWidth: 320\n---\nkanban\n  a[A]",
                theme: Theme(isDark: false), width: 900))
        let snug = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: "kanban\n  a[A]", theme: Theme(isDark: false), width: 900))
        XCTAssertGreaterThan(board.width, snug.width)

        // A board's key over a pie, a gantt's over a pie, and an empty title.
        for source in [
            "---\nconfig:\n  kanban:\n    ticketBaseUrl: 'x'\n---\npie\n  \"A\" : 1",
            "---\ndisplayMode: compact\n---\npie\n  \"A\" : 1",
            "---\ntitle:\n---\npie\n  \"A\" : 1",
        ] {
            guard case .pie? = MermaidDiagram.parse(source) else {
                return XCTFail("a pie with a spare key is still a pie: \(source)")
            }
        }
    }

    func testWhatAPreambleRefuses() {
        for source in [
            // A setting whose value names something nobody can draw.
            "---\nconfig:\n  theme: nightfall\n---\npie\n  \"A\" : 1",
            "---\ndisplayMode: roomy\n---\ngantt\n  section S\n  A : a1, 2024-01-01, 3d",
            "---\nconfig:\n  kanban:\n    sectionWidth: nine\n---\nkanban\n  a[A]",
            // A name in the preamble and a name in the diagram: two names, and
            // no way to know which one Mermaid would show.
            "---\ntitle: One\n---\npie\n  title Two\n  \"A\" : 1",
            // Opened and never closed, and named twice.
            "---\ntitle: One\npie\n  \"A\" : 1",
            "---\ntitle: One\ntitle: Two\n---\npie\n  \"A\" : 1",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
    }

    func testALabelIsBrokenWhereTheAuthorBrokeIt() throws {
        let chart = try XCTUnwrap(flowchart("flowchart TD\n  A[First<br/>Second] --> B[Plain]"))
        XCTAssertEqual(chart.nodes[0].label, "First<br/>Second")
        // Two lines make the box taller than a one-line box, not wider.
        let two = DocumentLayout(
            document: Document(text: "```mermaid\nflowchart TD\n  A[First<br/>Second]\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        let one = DocumentLayout(
            document: Document(text: "```mermaid\nflowchart TD\n  A[First Second]\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        let tall = try XCTUnwrap(two.box(at: 0))
        let flat = try XCTUnwrap(one.box(at: 0))
        XCTAssertGreaterThan(tall.height, flat.height)
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
        let document = Document(text: "```mermaid\npie title Costs\n  \"A\" : none\n```")
        let layout = DocumentLayout(
            document: document, theme: Theme(isDark: false), columnWidth: 520)
        let box = try XCTUnwrap(layout.box(at: 0))
        XCTAssertFalse(box.segments.isEmpty)
    }
}
