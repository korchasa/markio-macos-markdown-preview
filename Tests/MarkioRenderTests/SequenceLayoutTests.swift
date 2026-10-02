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

    func testABoxIsItsColourAndNothingElse() throws {
        // An outline the height of the picture crosses every message that
        // passes between two groups, and the words written over that line are
        // the ones nobody can read.
        let source = diagram(
            """
                box rgb(210,236,214) Cluster
                    participant P2
                    participant P3
                end
                P1->>P2: one
                P2->>P3: two
                P3->>P4: three
            """)
        let parsed = try XCTUnwrap(MermaidDiagram.parse(source))
        let drawing = MermaidLayout.draw(parsed, theme: Theme(isDark: false), width: 900)
        let column = try XCTUnwrap(groupColumn(in: drawing))
        for case .path(let path, _, let lineWidth, false) in drawing.decorations
        where lineWidth > 0 {
            XCTAssertFalse(
                path.boundingBox.insetBy(dx: -1, dy: -1).contains(column),
                "nothing should be drawn around a group")
        }
    }

    func testABoxNobodyColouredIsStillVisible() throws {
        // It had an outline to show it before; without one it needs a tint of
        // its own, or its name would stand over nothing.
        let source = diagram(
            """
                box Cluster
                    participant P2
                    participant P3
                end
                P1->>P2: one
                P2->>P3: two
            """)
        let parsed = try XCTUnwrap(MermaidDiagram.parse(source))
        let theme = Theme(isDark: false)
        let drawing = MermaidLayout.draw(parsed, theme: theme, width: 900)
        let page = theme.forDiagrams.palette.codeBackground
        var tinted = false
        for case .path(let path, let colour, _, true) in drawing.decorations
        where path.boundingBox.height > drawing.contentRect.height * 0.7 {
            tinted = tinted || MermaidLayout.contrast(colour, page) > 1.01
        }
        XCTAssertTrue(tinted, "a box without a colour should still be a shade of its own")
    }

    /// The group's own fill: the tallest wide filled rectangle in the picture.
    private func groupColumn(in drawing: MermaidLayout.Drawing) -> CGRect? {
        var tallest = CGRect.zero
        for case .path(let path, _, _, true) in drawing.decorations {
            let box = path.boundingBox
            if box.width > 100, box.height > tallest.height { tallest = box }
        }
        return tallest == .zero ? nil : tallest
    }

    /// Somebody made partway through is a box or a figure standing on the
    /// message that makes them; the arrow touches it, and an actor's lifeline
    /// starts under the name written beneath the figure.
    func testAMadeParticipantIsReachedAndAnActorsNameStaysClear() throws {
        let parsed = try XCTUnwrap(
            MermaidDiagram.parse(
                """
                sequenceDiagram
                    participant A
                    create participant C as Carl
                    A->>C: make
                    create actor D as Donald
                    C->>D: hi
                """))
        let drawing = MermaidLayout.draw(parsed, theme: Theme(isDark: false), width: 900)
        var heads: [CGRect] = []
        var boxes: [CGRect] = []
        var strokes: [CGRect] = []
        for case .path(let path, _, _, let filled) in drawing.decorations {
            let box = path.boundingBox
            if filled {
                if box.width < 15, box.height < 15 { heads.append(box) }
                if box.width > 30 { boxes.append(box) }
            } else {
                strokes.append(box)
            }
        }
        var words: [CGRect] = []
        for case .glyphs(let line, let origin) in drawing.decorations {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            words.append(
                CGRect(x: origin.x, y: origin.y - ascent, width: width, height: ascent + descent))
        }
        heads.sort { $0.minY < $1.minY }
        XCTAssertEqual(heads.count, 2)

        // Carl's box is the one standing on the first message.
        let carl = try XCTUnwrap(boxes.first { $0.minY < heads[0].midY && $0.maxY > heads[0].midY })
        XCTAssertEqual(heads[0].maxX, carl.minX, accuracy: 0.5)

        // The figure: arms, body and legs in one stroke, wider than a line.
        let figure = try XCTUnwrap(
            strokes.first {
                $0.width > 5 && $0.height > 10 && $0.minY < heads[1].midY
                    && $0.maxY > heads[1].midY
            })
        XCTAssertEqual(heads[1].maxX, figure.minX, accuracy: 0.5)
        let name = try XCTUnwrap(
            words.first { abs($0.midX - figure.midX) < 1 && $0.minY >= figure.maxY - 1 })
        let lifeline = try XCTUnwrap(
            strokes.first { $0.width < 1 && abs($0.midX - figure.midX) < 1 })
        XCTAssertGreaterThanOrEqual(lifeline.minY, name.maxY)
    }

    /// A word over a lifeline sits on a plate that hides the line; the
    /// condition of an `alt`'s second arm was written straight across it.
    func testNoWordIsCrossedByALifeline() throws {
        let parsed = try XCTUnwrap(
            MermaidDiagram.parse(
                """
                sequenceDiagram
                    Alice->>Bob: Hello Bob, how are you?
                    alt is sick
                        Bob->>Alice: Not so good :(
                    else is well
                        Bob->>Alice: Feeling fresh like a daisy
                    end
                """))
        let drawing = MermaidLayout.draw(parsed, theme: Theme(isDark: false), width: 760)
        var lifelines: [CGRect] = []
        var plates: [CGRect] = []
        var words: [CGRect] = []
        for decoration in drawing.decorations {
            switch decoration {
            case .path(let path, _, _, false)
            where path.boundingBox.width < 1 && path.boundingBox.height > 100:
                lifelines.append(path.boundingBox)
            case .fill(let rect, _, _):
                plates.append(rect)
            case .glyphs(let line, let origin):
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
                words.append(
                    CGRect(
                        x: origin.x, y: origin.y - ascent, width: width, height: ascent + descent))
            default: continue
            }
        }
        XCTAssertEqual(lifelines.count, 2)
        for word in words {
            for lifeline in lifelines where word.intersects(lifeline.insetBy(dx: -0.5, dy: 0)) {
                XCTAssertTrue(
                    plates.contains { $0.contains(word) }, "a lifeline runs through \(word)")
            }
        }
    }
}
