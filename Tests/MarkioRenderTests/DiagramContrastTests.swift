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

    /// A colour an author wrote into a `box`, now that it is behind a whole
    /// column rather than a band of heading.
    @MainActor
    func testAnAuthorsColourIsLightenedUntilEverythingOnItReads() {
        let theme = Theme(isDark: false).forDiagrams
        let page = theme.palette.codeBackground
        let chosen: [(String, CGColor)] = [
            ("black", CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
            ("navy", CGColor(srgbRed: 0.05, green: 0.1, blue: 0.4, alpha: 1)),
            ("red", CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)),
            ("mid grey", CGColor(gray: 0.5, alpha: 1)),
            ("pale grey", CGColor(gray: 228 / 255, alpha: 1)),
            (
                "pale purple",
                CGColor(srgbRed: 226 / 255, green: 214 / 255, blue: 244 / 255, alpha: 1)
            ),
        ]
        for (name, colour) in chosen {
            let washed = MermaidLayout.wash(colour, on: page, keeping: theme)
            // The faintest lettering in a diagram is a message label, and it is
            // now written over this.
            XCTAssertGreaterThan(
                contrast(theme.palette.secondaryText, washed), 6.999, "message labels on \(name)")
            XCTAssertGreaterThan(contrast(theme.palette.text, washed), 7, "lettering on \(name)")
            // 1.4.11 again: lifelines, arrows and the outline of every
            // participant box are drawn on it too.
            XCTAssertGreaterThan(
                contrast(theme.palette.tableBorder, washed), 3, "lines on \(name)")
        }
    }

    /// A colour already pale enough is left exactly as it was written: the
    /// author picked it, and nothing is gained by moving it.
    @MainActor
    func testAPaleColourIsNotTouched() {
        let theme = Theme(isDark: false).forDiagrams
        let pale = CGColor(srgbRed: 210 / 255, green: 236 / 255, blue: 214 / 255, alpha: 1)
        let washed = MermaidLayout.wash(pale, on: theme.palette.codeBackground, keeping: theme)
        XCTAssertEqual(contrast(pale, washed), 1, accuracy: 0.001)
    }
}
