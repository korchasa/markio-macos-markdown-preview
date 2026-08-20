import AppKit
import XCTest

@testable import Markio
@testable import MarkioRender

/// Reading at a size the reader chose, per window.
final class ZoomTests: XCTestCase {
    func testZoomingScalesTheWholePageAndNotOnlyTheType() {
        let plain = Theme.Metrics()
        let large = plain.scaled(by: 2)
        XCTAssertEqual(large.bodySize, plain.bodySize * 2, accuracy: 0.001)
        XCTAssertEqual(large.paragraphSpacing, plain.paragraphSpacing * 2, accuracy: 0.001)
        XCTAssertEqual(large.listIndent, plain.listIndent * 2, accuracy: 0.001)
        XCTAssertEqual(large.codePadding, plain.codePadding * 2, accuracy: 0.001)
        XCTAssertEqual(large.zoom, 2, accuracy: 0.001)

        // A rule scaled down still has to be drawn.
        let small = plain.scaled(by: 0.1)
        XCTAssertGreaterThanOrEqual(small.ruleThickness, 0.5)
    }

    func testZoomingTwiceIsTheSameAsZoomingByTheProduct() {
        let twice = Theme.Metrics().scaled(by: 1.5).scaled(by: 2)
        let once = Theme.Metrics().scaled(by: 3)
        XCTAssertEqual(twice.bodySize, once.bodySize, accuracy: 0.001)
        XCTAssertEqual(twice.zoom, once.zoom, accuracy: 0.001)
    }

    func testTheFontsAndTheControlLabelGrowTogether() {
        let plain = Theme(isDark: false)
        let large = Theme(isDark: false, metrics: Theme.Metrics().scaled(by: 2))
        XCTAssertEqual(
            CTFontGetSize(large.body), CTFontGetSize(plain.body) * 2, accuracy: 0.001)
        XCTAssertEqual(
            CTFontGetSize(large.controlLabel), CTFontGetSize(plain.controlLabel) * 2,
            accuracy: 0.001)
        XCTAssertEqual(
            CTFontGetSize(large.headings[0]), CTFontGetSize(plain.headings[0]) * 2,
            accuracy: 0.001)
    }

    func testSteppingInAndOutTheSameNumberOfTimesLandsWhereItStarted() {
        var zoom: CGFloat = 1
        for _ in 0..<4 { zoom = Preferences.zoom(zoom, steppedBy: 1) }
        for _ in 0..<4 { zoom = Preferences.zoom(zoom, steppedBy: -1) }
        XCTAssertEqual(zoom, 1, accuracy: 0.0001)
    }

    func testSteppingStopsAtTheEndsRatherThanRunningOff() {
        var zoom: CGFloat = 1
        for _ in 0..<50 { zoom = Preferences.zoom(zoom, steppedBy: 1) }
        XCTAssertEqual(zoom, Preferences.zoomSteps.last)
        for _ in 0..<50 { zoom = Preferences.zoom(zoom, steppedBy: -1) }
        XCTAssertEqual(zoom, Preferences.zoomSteps.first)
    }

    func testAWindowsZoomIsKeptWithItsDocumentAndForgottenOnActualSize() throws {
        let url = URL(fileURLWithPath: "/tmp/markio-zoom-test-\(UUID().uuidString).md")
        XCTAssertNil(Preferences.zoom(for: url))

        Preferences.setScrollPosition(1234, for: url)
        Preferences.setZoom(1.6, for: url)
        XCTAssertEqual(try XCTUnwrap(Preferences.zoom(for: url)), 1.6, accuracy: 0.0001)
        // The two facts live in one record and must not overwrite each other.
        XCTAssertEqual(try XCTUnwrap(Preferences.scrollPosition(for: url)), 1234, accuracy: 0.5)

        Preferences.setZoom(nil, for: url)
        XCTAssertNil(Preferences.zoom(for: url))
        XCTAssertEqual(try XCTUnwrap(Preferences.scrollPosition(for: url)), 1234, accuracy: 0.5)
    }

    @MainActor
    func testTheStartingZoomComesFromTheSystemAndIsAStep() {
        let zoom = SystemTextSize.zoom
        XCTAssertTrue(Preferences.zoomSteps.contains { abs($0 - zoom) < 0.0001 })
        // With the system slider where it ships, the body text style comes back
        // at the system size and the factor is exactly one.
        let preferred = NSFont.preferredFont(forTextStyle: .body).pointSize
        if abs(preferred - NSFont.systemFontSize) < 0.01 {
            XCTAssertEqual(zoom, 1, accuracy: 0.0001)
        }
    }

    /// The page is re-measured when the zoom or the width changes, so the same
    /// number of points down is a different place in the text. What the reader
    /// tracks is the paragraph under their eyes.
    @MainActor
    func testTheReaderKeepsTheirPlaceAcrossAZoomAndAWidthChange() throws {
        let text = (1...200).map { "Paragraph number \($0), long enough to wrap." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(
            from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: true)
        window.layoutIfNeeded()

        // Reached through the window rather than through the controller: the
        // views are its own business, and a test is not a reason to publish them.
        // The window holds two of these — the document and the baseline it is
        // compared against — and the empty one is not the one under test.
        func documentScrolls(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scroll = view as? NSScrollView,
                let inner = scroll.documentView as? DocumentView, inner.layout.blockCount > 0
            {
                found.append(scroll)
            }
            for subview in view.subviews { found += documentScrolls(in: subview) }
            return found
        }
        let scroll = try XCTUnwrap(
            documentScrolls(in: try XCTUnwrap(window.contentView)).first)
        let view = try XCTUnwrap(scroll.documentView as? DocumentView)
        let layout = view.layout
        // The view has no height until it has laid something out, and a scroll
        // to a point past the bottom of a one-screen view goes nowhere.
        view.viewWillDraw()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        scroll.reflectScrolledClipView(scroll.contentView)
        view.viewWillDraw()
        let padding = view.verticalPadding
        /// The block at the top of the window, and how far into it the window
        /// has been scrolled — which is where the reader actually is.
        func place() -> (ordinal: Int, fraction: CGFloat) {
            let y = max(0, scroll.contentView.bounds.minY - padding)
            let ordinal = layout.index(atOffset: y)
            let height = layout.height(of: ordinal)
            guard height > 0 else { return (ordinal, 0) }
            return (ordinal, (y - layout.offset(of: ordinal)) / height)
        }
        let before = place()
        XCTAssertGreaterThan(before.ordinal, 0, "the test needs to be somewhere in the document")

        controller.zoomIn(nil)
        view.viewWillDraw()
        XCTAssertEqual(place().ordinal, before.ordinal)
        XCTAssertEqual(place().fraction, before.fraction, accuracy: 0.35)

        controller.widenColumn(nil)
        view.viewWillDraw()
        XCTAssertEqual(place().ordinal, before.ordinal)
        XCTAssertEqual(place().fraction, before.fraction, accuracy: 0.35)

        controller.actualSize(nil)
        window.close()
    }

    @MainActor
    func testADiagramGrowsWithThePageItSitsOn() throws {
        let source = """
            flowchart TD
                A[One] --> B[Two]
            """
        let diagram = try XCTUnwrap(MermaidDiagram.parse(source))
        let plain = MermaidLayout.draw(diagram, theme: Theme(isDark: false), width: 4000)
        let large = MermaidLayout.draw(
            diagram, theme: Theme(isDark: false, metrics: Theme.Metrics().scaled(by: 2)),
            width: 4000)
        XCTAssertGreaterThan(large.contentWidth, plain.contentWidth * 1.5)
        XCTAssertGreaterThan(large.size.height, plain.size.height * 1.5)
    }
}
