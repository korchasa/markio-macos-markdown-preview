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
            "journey\n  Make tea: 5",
            "journey",
            // Excluded days move every bar after them, so the chart would be
            // drawn on days its author did not ask for.
            "gantt\n  excludes weekends\n  Draft :3d",
            // Another date format would put the bars on the wrong days.
            "gantt\n  dateFormat DD-MM-YYYY\n  Draft :3d",
            // A reference to a task that was never named.
            "gantt\n  Draft :after nothing, 3d",
            // A unit this does not know.
            "gantt\n  Draft :3y",
            "gantt",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
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
        XCTAssertTrue(graph.commits[4].highlighted)
    }

    func testWhatThePlotsRefuse() {
        for source in [
            // A point outside the square, and one with no coordinates at all.
            "quadrantChart\n  A: [1.4, 0.2]",
            "quadrantChart\n  A: [0.2]",
            "quadrantChart\n  x-axis Low --> High",
            // Series that do not line up with the names under them.
            "xychart-beta\n  x-axis [a, b]\n  bar [1, 2, 3]",
            "xychart-beta\n  bar [1, 2]\n  line [1, 2, 3]",
            "xychart-beta\n  x-axis [a, b]",
            // A cherry-pick needs a commit this never recorded, and a merge of
            // a branch nothing opened has nothing to point at.
            "gitGraph\n  commit\n  cherry-pick id: \"x\"",
            "gitGraph\n  commit\n  merge nothing",
            "gitGraph\n  commit\n  checkout nothing",
            // Turning the lanes on their side is a layout this has not got.
            "gitGraph TB:\n  commit",
            "gitGraph",
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
        XCTAssertEqual(
            diagram.boxes[0].compartments[0], ["id: 1", "text: opens fast.", "risk: high"])
        XCTAssertEqual(diagram.links.count, 1)
        XCTAssertEqual(diagram.links[0].label, "verifies")
        // The arrow runs from the thing that verifies to the thing verified.
        XCTAssertEqual(diagram.links[0].from, 1)
        XCTAssertEqual(diagram.links[0].to, 0)
    }

    func testWhatTheBoardsRefuse() {
        for source in [
            // A hole in the packet, and two fields over one bit.
            "packet-beta\n0-15: \"A\"\n20-31: \"B\"",
            "packet-beta\n0-15: \"A\"\n8-31: \"B\"",
            "packet-beta\n0-15",
            "packet-beta",
            // Metadata this does not draw, and a card with no column above it.
            "kanban\n  Todo\n    t1[A]@{ colour: 'red' }",
            "kanban\n    t1[A]\n  Todo",
            "kanban",
            // A relation this does not know, and an unclosed block.
            "requirementDiagram\n requirement a {\n id: 1\n }\n a - invents -> a",
            "requirementDiagram\n requirement a {\n id: 1",
            "requirementDiagram",
        ] {
            XCTAssertNil(MermaidDiagram.parse(source), source)
        }
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

    func testWhatTheFlowsRefuse() {
        for source in [
            // A flow back to where it came from makes the ranks meaningless.
            "sankey-beta\nA,B,1\nB,A,1",
            "sankey-beta\nA,A,1",
            "sankey-beta\nA,B",
            "sankey-beta\nA,B,none",
            "sankey-beta\nA,B,0",
            "sankey-beta",
            // A node cannot both carry a number and hold other nodes.
            "treemap-beta\n\"A\": 5\n    \"B\": 2",
            "treemap-beta\n\"A\"\n    \"B\": none",
            "treemap-beta\n\"A\"\n    \"B\": 0",
            "treemap-beta",
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
