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
