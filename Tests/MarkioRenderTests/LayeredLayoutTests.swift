import CoreText
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

/// The layered pipeline on its own, on graphs small enough to reason about.
final class LayeredCoreTests: XCTestCase {
    private let spacing = LayeredLayout.Spacing(node: 32, layer: 40, edge: 10)
    private let box = CGSize(width: 60, height: 30)

    private func layout(
        _ count: Int, _ edges: [(Int, Int)], labels: [Int: CGSize] = [:]
    ) -> LayeredLayout.Result {
        LayeredLayout.layout(
            sizes: Array(repeating: box, count: count),
            edges: edges.enumerated().map {
                LayeredLayout.Edge(from: $0.element.0, to: $0.element.1, label: labels[$0.offset])
            },
            spacing: spacing)
    }

    func testAChainStandsInOneStraightColumn() {
        let result = layout(3, [(0, 1), (1, 2)])
        XCTAssertEqual(result.frames[0].midX, result.frames[1].midX, accuracy: 0.5)
        XCTAssertEqual(result.frames[1].midX, result.frames[2].midX, accuracy: 0.5)
        XCTAssertLessThan(result.frames[0].maxY, result.frames[1].minY)
        XCTAssertLessThan(result.frames[1].maxY, result.frames[2].minY)
        XCTAssertEqual(result.routes[0].count, 2, "a line between neighbours is one stroke")
        XCTAssertEqual(result.routes[0].first!.y, result.frames[0].maxY, accuracy: 0.5)
        XCTAssertEqual(result.routes[0].last!.y, result.frames[1].minY, accuracy: 0.5)
    }

    /// Longest path would put the end of a shortcut as low as the long way
    /// round; network simplex keeps every edge as short as it can.
    func testLayersKeepEdgesShort() {
        // 0 → 1 → 2 → 3, and 4 → 3 written last: 4 belongs just above 3, not
        // at the top.
        let result = layout(5, [(0, 1), (1, 2), (2, 3), (4, 3)])
        XCTAssertEqual(result.frames[4].midY, result.frames[2].midY, accuracy: 0.5)
    }

    /// A line back to a box written earlier is laid out as if it pointed the
    /// other way, and drawn from where it really starts.
    func testABackEdgeRunsFromItsOwnStart() {
        let result = layout(2, [(0, 1), (1, 0)])
        XCTAssertLessThan(result.frames[0].maxY, result.frames[1].minY)
        let back = result.routes[1]
        XCTAssertEqual(back.first!.y, result.frames[1].minY, accuracy: 0.5)
        XCTAssertEqual(back.last!.y, result.frames[0].maxY, accuracy: 0.5)
        XCTAssertNotEqual(result.routes[0].first!.x, back.last!.x, "two lines, two places")
    }

    func testWordsGetALayerOfTheirOwn() {
        let words = CGSize(width: 50, height: 28)
        let result = layout(2, [(0, 1)], labels: [0: words])
        let label = try! XCTUnwrap(result.labels[0])
        XCTAssertGreaterThan(label.minY, result.frames[0].maxY)
        XCTAssertLessThan(label.maxY, result.frames[1].minY)
        XCTAssertEqual(label.size, words)
    }

    func testOrderRemovesACrossing() {
        // Written so that the first order crosses: 0 → 3 and 1 → 2.
        let result = layout(4, [(0, 3), (1, 2)])
        let firstLeft = result.frames[0].midX < result.frames[1].midX
        let targetLeft = result.frames[3].midX < result.frames[2].midX
        XCTAssertEqual(firstLeft, targetLeft)
    }

    func testLinesNeverCrossTheBoxesBetweenTheirEnds() {
        // A long edge past a box in the middle layer.
        let result = layout(3, [(0, 1), (1, 2), (0, 2)])
        let long = result.routes[2]
        let middle = result.frames[1].insetBy(dx: 1, dy: 1)
        for index in 1..<long.count {
            let a = long[index - 1]
            let b = long[index]
            let run = CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            XCTAssertFalse(run.intersects(middle), "segment \(a)–\(b) crosses the middle box")
            XCTAssertTrue(a.x == b.x || a.y == b.y, "segments run along or across the layers")
        }
    }
}

extension LayeredCoreTests {
    /// Two lines into one box from boxes written on either side of it: no
    /// cycle, so neither is turned round.
    func testAnEdgeOutsideACycleKeepsItsDirection() {
        // A --> C, then B --> C: C was written before B.
        let result = layout(3, [(0, 1), (2, 1)])
        XCTAssertLessThan(result.frames[2].maxY, result.frames[1].minY)
    }

    func testCyclesAreTheStronglyConnectedParts() {
        let parts = LayeredLayout.cycles(
            count: 5,
            edges: [(0, 1), (1, 2), (2, 0), (2, 3), (3, 4)].map {
                LayeredLayout.Edge(from: $0.0, to: $0.1, label: nil)
            })
        XCTAssertEqual(parts[0], parts[1])
        XCTAssertEqual(parts[1], parts[2])
        XCTAssertNotEqual(parts[2], parts[3])
        XCTAssertNotEqual(parts[3], parts[4])
    }
}

extension LayeredCoreTests {
    /// The line of an edge that was not turned round runs from where it starts,
    /// whichever of its ends was written first.
    func testALineOutsideACycleRunsFromItsStart() {
        let result = layout(3, [(0, 1), (2, 1)])
        XCTAssertEqual(result.routes[1].first!.y, result.frames[2].maxY, accuracy: 0.5)
        XCTAssertEqual(result.routes[1].last!.y, result.frames[1].minY, accuracy: 0.5)
    }
}

extension LayeredCoreTests {
    /// A point on a frame's border stands beyond every box, however short
    /// the edge to it would otherwise be.
    func testAPinnedBoxStandsBeyondEverything() {
        let result = LayeredLayout.layout(
            sizes: [box, box, box, .zero],
            edges: [(0, 1), (1, 2), (3, 1)].map {
                LayeredLayout.Edge(from: $0.0, to: $0.1, label: nil)
            },
            pinned: [3: .first], spacing: spacing)
        XCTAssertLessThan(result.frames[3].maxY, result.frames[0].minY)
        XCTAssertEqual(result.routes[2].first!.y, result.frames[3].maxY, accuracy: 0.5)
        XCTAssertEqual(result.routes[2].last!.y, result.frames[1].minY, accuracy: 0.5)
    }

    /// A frame's own layout ran a line to a point on its border, and the
    /// layout around the frame arrives at exactly that point.
    func testAFixedPortIsWhereTheLineArrives() {
        let wide = CGSize(width: 200, height: 30)
        let result = LayeredLayout.layout(
            sizes: [box, wide],
            edges: [LayeredLayout.Edge(from: 0, to: 1, label: nil, toPort: 170)],
            spacing: spacing)
        XCTAssertEqual(result.routes[0].last!.x, result.frames[1].minX + 170, accuracy: 0.5)
        XCTAssertEqual(result.routes[0].last!.y, result.frames[1].minY, accuracy: 0.5)
    }
}

extension LayeredLayoutTests {
    /// A line to a box inside a frame is laid out inside the frame too, so it
    /// passes no box on its way in, whichever way the frame's layers run.
    func testALineIntoAFrameAvoidsTheBoxesInside() throws {
        for direction in ["TD", "BT"] {
            let drawn = try XCTUnwrap(
                geometry(
                    """
                    flowchart \(direction)
                        outside --> deep
                        subgraph group [Group]
                            first --> second --> deep
                        end
                    """
                ))
            let line = try XCTUnwrap(drawn.lines.first { $0.ends == [0, 1] })
            for (index, box) in drawn.nodes.enumerated() where index > 1 {
                let inner = box.insetBy(dx: 2, dy: 2)
                for step in 1..<line.points.count {
                    let a = line.points[step - 1]
                    let b = line.points[step]
                    let run = CGRect(
                        x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x),
                        height: abs(a.y - b.y))
                    XCTAssertFalse(
                        run.intersects(inner), "\(direction): the line crosses box \(index)")
                }
            }
        }
    }

    /// A frame's name is written where no line runs through it: moved along
    /// the strip over the frame, or with the line ending on the frame stopped
    /// above it.
    func testNoLineRunsThroughAFramesName() throws {
        let sources = [
            """
            stateDiagram-v2
                [*] --> First
                state First {
                    [*] --> second
                    second --> [*]
                }
                [*] --> NamedComposite
                NamedComposite: Another Composite
                state NamedComposite {
                    [*] --> namedSimple
                    namedSimple --> [*]
                    namedSimple: Another simple
                }
            """,
            """
            flowchart TB
                c1-->a2
                subgraph one
                a1-->a2
                end
                subgraph two
                b1-->b2
                end
                subgraph three
                c1-->c2
                end
                one --> two
                three --> two
                two --> c2
            """,
            try String(contentsOfFile: "test-fixtures/layout/classes.mmd", encoding: .utf8),
        ]
        for source in sources {
            let diagram = try XCTUnwrap(MermaidDiagram.parse(source), "did not parse")
            let drawing = MermaidLayout.draw(diagram, theme: Theme(isDark: false), width: 2000)
            let drawn = try XCTUnwrap(drawing.geometry)
            XCTAssertFalse(drawn.frames.isEmpty)
            for frame in drawn.frames {
                var names: [CGRect] = []
                for case .glyphs(let line, let origin) in drawing.decorations
                where origin.x >= frame.minX && origin.x < frame.maxX
                    && abs(origin.y - frame.minY) < 30
                {
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
                    names.append(
                        CGRect(
                            x: origin.x, y: origin.y - ascent, width: width,
                            height: ascent + descent))
                }
                XCTAssertFalse(names.isEmpty, "no name over \(frame)")
                for name in names {
                    for line in drawn.lines {
                        for (a, b) in zip(line.points, line.points.dropFirst()) {
                            let run = CGRect(
                                x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x),
                                height: abs(a.y - b.y))
                            XCTAssertFalse(
                                run.intersects(name.insetBy(dx: 1, dy: 1)),
                                "a line runs through the name at \(name)")
                        }
                    }
                }
            }
        }
    }
}

extension LayeredCoreTests {
    /// Relations that read the same both ways are laid out in the order the
    /// boxes were written, cycle or not.
    func testInTextOrderEveryLineRunsFromTheBoxWrittenFirst() {
        let result = LayeredLayout.layout(
            sizes: [box, box],
            edges: [LayeredLayout.Edge(from: 1, to: 0, label: nil)],
            inTextOrder: true, spacing: spacing)
        XCTAssertLessThan(result.frames[0].maxY, result.frames[1].minY)
        XCTAssertEqual(result.routes[0].first!.y, result.frames[1].minY, accuracy: 0.5)
    }

    /// A line to a point on a frame's border keeps the direction the point
    /// was pinned for, even when text order would turn it round.
    func testALineToAPinnedPointIsNeverTurned() {
        let result = LayeredLayout.layout(
            sizes: [box, .zero],
            edges: [LayeredLayout.Edge(from: 1, to: 0, label: nil)],
            pinned: [1: .first], inTextOrder: true, spacing: spacing)
        XCTAssertLessThan(result.frames[1].maxY, result.frames[0].minY)
    }

    /// Two lines held at the two ends of one wide box cross unless the boxes
    /// they come from stand in the same order.
    func testHeldPortsDecideTheOrderAbove() {
        let wide = CGSize(width: 300, height: 30)
        let result = LayeredLayout.layout(
            sizes: [box, box, wide],
            edges: [
                LayeredLayout.Edge(from: 0, to: 2, label: nil, toPort: 280),
                LayeredLayout.Edge(from: 1, to: 2, label: nil, toPort: 20),
            ],
            spacing: spacing)
        XCTAssertGreaterThan(result.frames[0].midX, result.frames[1].midX)
    }
}
