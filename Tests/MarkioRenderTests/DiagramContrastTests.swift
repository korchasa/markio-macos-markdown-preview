import AppKit
import XCTest

@testable import MarkioRender

/// The colours a diagram is drawn in, stated as contrast ratios.
///
/// A diagram is mostly lines, and lines are what a dark page takes away first:
/// drawn in the reader's own dark palette, a box outline and the card behind it
/// differed by a shade nobody could see. These are the numbers that say the
/// picture is legible, rather than a screenshot somebody looked at once.
final class DiagramContrastTests: XCTestCase {
    /// WCAG 2.1 relative luminance and contrast ratio, which is what the levels
    /// quoted below are defined in terms of.
    private func contrast(_ one: CGColor, _ other: CGColor) -> Double {
        func luminance(_ color: CGColor) -> Double {
            let rgb =
                color.converted(
                    to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                    options: nil) ?? color
            let parts = (rgb.components ?? [0, 0, 0, 1]).prefix(3).map { part -> Double in
                let value = Double(part)
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
        }
        let one = luminance(one)
        let other = luminance(other)
        return (max(one, other) + 0.05) / (min(one, other) + 0.05)
    }

    private var palette: Theme.Palette { Theme(isDark: true).forDiagrams.palette }

    func testADiagramIsDrawnOnAWhitePageWhicheverPageItSitsOn() {
        for isDark in [true, false] {
            let page = Theme(isDark: isDark).forDiagrams.palette
            let white = CGColor(gray: 1, alpha: 1)
            XCTAssertEqual(contrast(page.codeBackground, white), 1, accuracy: 0.001)
            XCTAssertEqual(contrast(page.background, white), 1, accuracy: 0.001)
        }
    }

    func testLetteringIsWellPastWhatWCAGAsksOfText() {
        // AAA for body text is 7:1; a diagram's lettering is small and often
        // sits over a line, so it is held to that rather than to AA's 4.5.
        XCTAssertGreaterThan(contrast(palette.text, palette.codeBackground), 7)
        XCTAssertGreaterThan(contrast(palette.text, palette.tableHeaderBackground), 7)
        XCTAssertGreaterThan(contrast(palette.secondaryText, palette.codeBackground), 7)
        XCTAssertGreaterThan(contrast(palette.secondaryText, palette.tableHeaderBackground), 7)
    }

    func testOutlinesAndConnectingLinesArePastWhatWCAGAsksOfGraphics() {
        // 1.4.11 Non-text Contrast: 3:1 for the parts of a picture that carry
        // meaning. Every box outline, lifeline and arrow is drawn in this one.
        XCTAssertGreaterThan(contrast(palette.tableBorder, palette.codeBackground), 3)
        XCTAssertGreaterThan(contrast(palette.tableBorder, palette.tableHeaderBackground), 3)
    }

    func testAFilledBoxReadsAsABoxAgainstThePage() {
        // Faint on purpose — the lettering on it keeps full contrast — but the
        // fill still has to be a shade the eye separates from white.
        let against = contrast(palette.tableHeaderBackground, palette.codeBackground)
        XCTAssertGreaterThan(against, 1.05)
        XCTAssertLessThan(against, 1.3)
    }

    func testTheDocumentAroundADiagramIsUntouched() {
        // Only the picture is repainted: a dark page stays dark.
        let dark = Theme(isDark: true)
        XCTAssertEqual(
            contrast(dark.palette.background, dark.forDiagrams.palette.background) > 10, true)
        XCTAssertTrue(dark.forDiagrams.isDark)
    }
}
