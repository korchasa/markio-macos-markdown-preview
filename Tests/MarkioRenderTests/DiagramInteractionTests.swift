import AppKit
import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// What a reader can do with a drawn diagram that they cannot do with a fence.
@MainActor
final class DiagramInteractionTests: XCTestCase {
    private let source = """
        flowchart TD
            A[One] --> B[Two]
            B --> C[Three]
        """

    func testADrawnDiagramSaysSoAndAFenceOfTextDoesNot() throws {
        let drawn = DocumentLayout(
            document: Document(text: "```mermaid\n\(source)\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        XCTAssertEqual(try XCTUnwrap(drawn.box(at: 0)).codeRegion?.isDiagram, true)

        // The same fence with something the layout cannot draw stays text. A
        // subgraph left open is not a diagram in any Mermaid, which keeps this
        // example refused however many constructs are added.
        let refused = DocumentLayout(
            document: Document(text: "```mermaid\nflowchart TD\n subgraph a\n A --> B\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        XCTAssertEqual(try XCTUnwrap(refused.box(at: 0)).codeRegion?.isDiagram, false)

        let code = DocumentLayout(
            document: Document(text: "```swift\nlet x = 1\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        XCTAssertEqual(try XCTUnwrap(code.box(at: 0)).codeRegion?.isDiagram, false)
    }

    func testNothingInAPictureIsCutOffByItsOwnEdge() throws {
        // A machine that returns to its start sends one edge past three boxes,
        // and that edge used to reach outside the width the drawing claimed and
        // be cut off by the bitmap. The check is the property itself rather than
        // any one route to it: every line drawn stands inside the picture that
        // says how big it is.
        let source = """
            stateDiagram-v2
                [*] --> Still
                Still --> Moving
                Moving --> Crash
                Crash --> [*]
                Still --> [*]
            """
        let drawing = MermaidLayout.draw(
            try XCTUnwrap(MermaidDiagram.parse(source)), theme: Theme(isDark: false), width: 700)
        var drawn = CGRect.null
        for decoration in drawing.decorations {
            if case .path(let path, _, _, _) = decoration {
                drawn = drawn.union(path.boundingBoxOfPath)
            }
        }
        XCTAssertFalse(drawn.isNull)
        XCTAssertGreaterThanOrEqual(drawn.minX, 0)
        XCTAssertGreaterThanOrEqual(drawn.minY, 0)
        XCTAssertLessThanOrEqual(drawn.maxX, drawing.size.width)
        XCTAssertLessThanOrEqual(drawn.maxY, drawing.size.height)
    }

    func testADiagramFarWiderThanTheColumnStillEndsInsideIt() throws {
        // Sixteen participants passing wordy messages to each other measure some
        // six thousand points across. The layout answers that by drawing the
        // picture smaller, which stops being proportional once the type is down
        // near a point — and the leftover used to hang past the column and be
        // cut off by its edge. Whatever the layout cannot fit is squeezed as
        // drawn instead, so the picture ends inside the column at any width.
        var lines = ["sequenceDiagram"]
        let names = (1...16).map { "Participant number \($0)" }
        for name in names { lines.append("    participant P\(name.count)\(name) as \(name)") }
        for index in 0..<(names.count - 1) {
            lines.append(
                "    P\(names[index].count)\(names[index])->>"
                    + "P\(names[index + 1].count)\(names[index + 1]): "
                    + "a message with a good many more words in it than a short label"
                    + " would ever need")
        }
        let text = "```mermaid\n" + lines.joined(separator: "\n") + "\n```"

        for column in [400.0, 520.0, 700.0] as [CGFloat] {
            let layout = DocumentLayout(
                document: Document(text: text), theme: Theme(isDark: false), columnWidth: column)
            let box = try XCTUnwrap(layout.box(at: 0))
            let region = try XCTUnwrap(box.codeRegion)
            XCTAssertTrue(region.isDiagram)
            var drawn = CGRect.null
            for decoration in box.decorations {
                switch decoration {
                case .fill(let rect, _, _), .stroke(let rect, _, _), .image(_, let rect):
                    drawn = drawn.union(rect)
                case .path(let path, _, _, _):
                    drawn = drawn.union(path.boundingBoxOfPath)
                case .glyphs(let line, let origin):
                    let bounds = CTLineGetBoundsWithOptions(line, [])
                    drawn = drawn.union(bounds.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
            XCTAssertFalse(drawn.isNull, "column \(column)")
            XCTAssertLessThanOrEqual(drawn.maxX, region.rect.maxX + 0.5, "column \(column)")
        }
    }

    /// A board is read by glancing across its columns, so a long title makes a
    /// taller card and not a column as wide as the sentence.
    func testALongCardTitleMakesATallerCardAndNotAWiderBoard() throws {
        let board = """
            kanban
            todo[Todo]
              id3[A card title far longer than any column would be by default]
            """
        let wordy = try XCTUnwrap(
            DocumentRenderer.diagram(source: board, theme: Theme(isDark: false), width: 900))
        let short = """
            kanban
            todo[Todo]
              id3[Short]
            """
        let brief = try XCTUnwrap(
            DocumentRenderer.diagram(source: short, theme: Theme(isDark: false), width: 900))
        XCTAssertEqual(wordy.width, brief.width)
        XCTAssertGreaterThan(wordy.height, brief.height)
    }

    func testADiagramFillsTheRoomItNeedsAndNoMore() throws {
        // A picture wider than the room it is given is drawn to the room. Two
        // device pixels per point, which is what a Retina paste needs.
        let long = """
            flowchart LR
                A[A step with a long name] --> B[Another step with a long name]
                B --> C[A third step with a long name]
            """
        let filled = try XCTUnwrap(
            DocumentRenderer.diagram(source: long, theme: Theme(isDark: false), width: 400))
        XCTAssertEqual(filled.width, 800)
        XCTAssertGreaterThan(filled.height, 0)
    }

    func testASmallDiagramIsNotPaddedOutToTheWindow() throws {
        // The width is a limit, not a frame: three small boxes asked for at 900
        // points come back the size of three small boxes, not centred in a field
        // of empty card.
        let narrow = try XCTUnwrap(
            DocumentRenderer.diagram(source: source, theme: Theme(isDark: false), width: 400))
        let wide = try XCTUnwrap(
            DocumentRenderer.diagram(source: source, theme: Theme(isDark: false), width: 900))
        XCTAssertLessThan(narrow.width, 800)
        XCTAssertEqual(wide.width, narrow.width)
        XCTAssertEqual(wide.height, narrow.height)
    }

    func testAFenceItCannotDrawHasNoPictureToCopy() {
        XCTAssertNil(
            DocumentRenderer.diagram(
                source: "flowchart TD\n subgraph a\n A --> B", theme: Theme(isDark: false),
                width: 400))
    }

    func testAnEnlargedDiagramRemembersWhichOneItIs() throws {
        let host = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let panel = try XCTUnwrap(
            DiagramWindow.present(source: source, theme: Theme(isDark: false), over: host))
        defer { panel.close() }
        // The source is what tells a second click it is the same diagram.
        XCTAssertEqual(panel.source, source)
        XCTAssertGreaterThan(panel.frame.width, 0)
        XCTAssertGreaterThan(panel.frame.height, 0)
    }

    func testAnEnlargedDiagramIsPutAwayByEscapeAndByAClick() throws {
        let host = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)

        // Escape reaches a window as an ordinary key press. Only a text view in
        // the responder chain turns one into `cancelOperation`, so a panel that
        // waits for that call waits for ever.
        let byEscape = try XCTUnwrap(
            DiagramWindow.present(source: source, theme: Theme(isDark: false), over: host))
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: byEscape.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        byEscape.keyDown(with: escape)
        XCTAssertFalse(byEscape.isVisible)

        // A click on the picture, which is what a reader who opened it with a
        // click reaches for. The image view does not answer a click of its own,
        // so it travels up to the panel.
        let byClick = try XCTUnwrap(
            DiagramWindow.present(source: source, theme: Theme(isDark: false), over: host))
        let picture = try XCTUnwrap(
            byClick.contentView.map { view -> NSView? in
                var found: NSView?
                func walk(_ view: NSView) {
                    if view is NSImageView { found = view }
                    view.subviews.forEach(walk)
                }
                walk(view)
                return found
            } ?? nil)
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: byClick.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
        picture.mouseDown(with: click)
        XCTAssertFalse(byClick.isVisible)

        // ⌘W belongs to the document window, so the panel leaves it alone.
        let untouched = try XCTUnwrap(
            DiagramWindow.present(source: source, theme: Theme(isDark: false), over: host))
        defer { untouched.close() }
        XCTAssertFalse(untouched.styleMask.contains(.closable))
    }
}

/// The shape of the window a diagram is enlarged into.
@MainActor
final class DiagramWindowSizeTests: XCTestCase {
    private let room = CGSize(width: 1400, height: 800)

    func testAPictureNarrowerThanTheRoomKeepsItsOwnShape() {
        // The renderer treats the width it is given as a limit, so a small
        // diagram comes back at its own size. Before this, the panel took the
        // width that had been asked for and the picture was stretched into it.
        let picture = CGSize(width: 420, height: 300)
        let size = DiagramWindow.panelSize(picture: picture, room: room)
        XCTAssertEqual(size.width, 420, accuracy: 0.001)
        XCTAssertEqual(size.height, 300, accuracy: 0.001)
    }

    func testAPictureTallerThanTheRoomShrinksOnBothSides() {
        let picture = CGSize(width: 600, height: 1600)
        let size = DiagramWindow.panelSize(picture: picture, room: room)
        XCTAssertEqual(size.height, 800, accuracy: 0.001)
        XCTAssertEqual(
            size.width / size.height, picture.width / picture.height, accuracy: 0.001)
    }

    func testAPictureWiderThanTheRoomShrinksOnBothSides() {
        let picture = CGSize(width: 2800, height: 700)
        let size = DiagramWindow.panelSize(picture: picture, room: room)
        XCTAssertEqual(size.width, 1400, accuracy: 0.001)
        XCTAssertEqual(
            size.width / size.height, picture.width / picture.height, accuracy: 0.001)
    }

    func testAnEmptyPictureAsksForNoWindow() {
        XCTAssertEqual(DiagramWindow.panelSize(picture: .zero, room: room), .zero)
    }
}

/// How sharp the enlarged picture is kept as the reader zooms into it.
@MainActor
final class DiagramZoomTests: XCTestCase {
    func testTheBitmapIsDrawnDenserAsTheZoomGrows() {
        // Whole steps, so a slow pinch does not redraw at every frame.
        XCTAssertEqual(DiagramWindow.bitmapScale(for: 1), 2)
        XCTAssertEqual(DiagramWindow.bitmapScale(for: 1.5), 3)
        XCTAssertEqual(DiagramWindow.bitmapScale(for: 2), 4)
        XCTAssertEqual(DiagramWindow.bitmapScale(for: 3.2), 7)
    }

    func testTheDensityNeverFallsBelowTheScreenNorRunsAway() {
        // Below 1 the picture is shown smaller than it was drawn, and drawing
        // it thinner than the screen would help nobody.
        XCTAssertEqual(DiagramWindow.bitmapScale(for: 0.3), 2)
        // A diagram blown up eight times is already unreadable in the other
        // direction; past here the bitmap would only cost memory.
        XCTAssertEqual(DiagramWindow.bitmapScale(for: 8), 8)
        XCTAssertEqual(DiagramWindow.bitmapScale(for: 40), 8)
    }
}
