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
