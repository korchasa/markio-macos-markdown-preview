import CoreText
import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// The formula typesetter: what it reads, what it refuses, and whether the
/// pieces end up where a reader expects them.
@MainActor
final class MathTests: XCTestCase {
    private let color = CGColor(gray: 0, alpha: 1)
    private var font: CTFont { NSFont.systemFont(ofSize: 16) as CTFont }

    private func box(_ source: String) -> MathBox? {
        MathFormula.box(source: source, base: font, color: color)
    }

    func testTheFormulasPeopleActuallyWrite() {
        for source in [
            "e^{i\\pi} + 1 = 0",
            "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}",
            "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            "\\alpha \\leq \\beta \\times \\gamma \\to \\infty",
            "\\sin^2 \\theta + \\cos^2 \\theta = 1",
            "f(x) \\, dx",
            "\\left( \\frac{a}{b} \\right)",
            "\\text{count} > 0",
            "3.14 \\approx \\pi",
        ] {
            XCTAssertTrue(MathFormula.canTypeset(source), source)
            XCTAssertNotNil(box(source), source)
        }
    }

    func testWhatItCannotSetItRefuses() {
        // Every one of these has to come back nil, because the alternative is a
        // formula drawn as something the author did not write. Refusing shows
        // the source instead, which is always at least true.
        for source in [
            "\\begin{matrix} a & b \\end{matrix}",
            "\\unknowncommand{x}",
            "\\mathbb{R}",
            "\\sqrt[3]{x}",
            "a \\\\ b",
            "{a",
            "a}",
            "x^",
            "x^2^3",
            "",
        ] {
            XCTAssertFalse(MathFormula.canTypeset(source), source)
            XCTAssertNil(box(source), source)
        }
    }

    /// `canTypeset` runs on a background queue with no fonts, and decides what
    /// Find sees; `box` decides what is drawn. They must never disagree.
    func testTheTextAndTheDrawingAgreeOnWhatIsAFormula() {
        for source in ["x^2", "\\frac{a}{b}", "\\nope", "a & b"] {
            XCTAssertEqual(MathFormula.canTypeset(source), box(source) != nil, source)
        }
    }

    func testAFractionIsTallerThanItsPartsAndSitsAcrossTheBaseline() throws {
        let plain = try XCTUnwrap(box("a"))
        let fraction = try XCTUnwrap(box("\\frac{a}{b}"))
        XCTAssertGreaterThan(fraction.ascent, plain.ascent)
        XCTAssertGreaterThan(fraction.descent, plain.descent)
        // The bar is the only rule in it, and it has to be inside the box.
        let rules = fraction.items.compactMap { item -> CGRect? in
            guard case .rule(let rect) = item else { return nil }
            return rect
        }
        XCTAssertEqual(rules.count, 1)
        XCTAssertLessThan(try XCTUnwrap(rules.first).midY, 0)
        XCTAssertGreaterThan(try XCTUnwrap(rules.first).midY, -fraction.ascent)
    }

    func testASuperscriptAddsWidthAndHeightWithoutMovingTheBaseline() throws {
        let plain = try XCTUnwrap(box("x"))
        let scripted = try XCTUnwrap(box("x^2"))
        XCTAssertGreaterThan(scripted.width, plain.width)
        XCTAssertGreaterThan(scripted.ascent, plain.ascent)
        XCTAssertEqual(scripted.descent, plain.descent, accuracy: 0.01)
    }

    func testARootCoversItsContent() throws {
        let content = try XCTUnwrap(box("x + 1"))
        let root = try XCTUnwrap(box("\\sqrt{x + 1}"))
        XCTAssertGreaterThan(root.width, content.width)
        // The bar has to reach across the content it covers, not merely exist.
        let bar = try XCTUnwrap(
            root.items.compactMap { item -> CGRect? in
                guard case .rule(let rect) = item else { return nil }
                return rect
            }.first
        )
        XCTAssertGreaterThanOrEqual(bar.width, content.width)
        XCTAssertLessThan(bar.midY, -content.ascent + 1)
    }

    /// A relation is set with more air around it than a plain letter — the
    /// difference between `a=b` and `a = b` without the author typing spaces.
    func testSpacingFollowsTheAtomClasses() throws {
        let tight = try XCTUnwrap(box("ab"))
        let relation = try XCTUnwrap(box("a=b"))
        let binary = try XCTUnwrap(box("a+b"))
        XCTAssertGreaterThan(relation.width, binary.width - tight.width)
        XCTAssertGreaterThan(binary.width, tight.width)
    }

    /// A leading minus is a sign, and a sign hugs what it negates.
    func testALeadingMinusIsNotSpacedLikeSubtraction() throws {
        let sign = try XCTUnwrap(box("-b"))
        let subtraction = try XCTUnwrap(box("a-b"))
        let letters = try XCTUnwrap(box("ab"))
        XCTAssertLessThan(sign.width - letters.width, subtraction.width - letters.width)
    }

    func testADrawnFormulaBecomesGlyphDecorationsInTheBlock() throws {
        let document = Document(text: "Euler wrote $e^{i\\pi} + 1 = 0$ once.")
        let layout = DocumentLayout(
            document: document, theme: Theme(isDark: false), columnWidth: 520)
        let box = try XCTUnwrap(layout.box(at: 0))
        let glyphs = box.decorations.filter {
            if case .glyphs = $0 { return true }
            return false
        }
        XCTAssertGreaterThan(glyphs.count, 3)
        // The formula is drawn, so the text carries one placeholder where it is.
        XCTAssertEqual(box.plainText, "Euler wrote \u{FFFC} once.")
    }

    func testAFormulaThatCannotBeSetKeepsItsSourceInTheText() throws {
        let document = Document(text: "Matrices: $\\begin{matrix} a \\end{matrix}$.")
        let layout = DocumentLayout(
            document: document, theme: Theme(isDark: false), columnWidth: 520)
        let box = try XCTUnwrap(layout.box(at: 0))
        XCTAssertEqual(box.plainText, "Matrices: \\begin{matrix} a \\end{matrix}.")
    }
}
