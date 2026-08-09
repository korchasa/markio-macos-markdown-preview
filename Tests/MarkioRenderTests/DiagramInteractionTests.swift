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

        // The same fence with something the layout cannot draw stays text.
        // An invisible link is a construct no layout here can honour, which
        // keeps this example refused however many diagram kinds are added.
        let refused = DocumentLayout(
            document: Document(text: "```mermaid\nflowchart TD\n A ~~~ B\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        XCTAssertEqual(try XCTUnwrap(refused.box(at: 0)).codeRegion?.isDiagram, false)

        let code = DocumentLayout(
            document: Document(text: "```swift\nlet x = 1\n```"),
            theme: Theme(isDark: false), columnWidth: 520)
        XCTAssertEqual(try XCTUnwrap(code.box(at: 0)).codeRegion?.isDiagram, false)
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
                source: "flowchart TD\n A ~~~ B", theme: Theme(isDark: false), width: 400))
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
