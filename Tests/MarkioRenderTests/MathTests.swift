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

    private func displayed(_ source: String) -> MathBox? {
        MathFormula.box(source: source, base: font, color: color, display: true)
    }

    private func rules(_ box: MathBox) -> [CGRect] {
        box.items.compactMap { item in
            guard case .rule(let rect) = item else { return nil }
            return rect
        }
    }

    private func glyphs(_ box: MathBox) -> [(line: CTLine, origin: CGPoint)] {
        box.items.compactMap { item in
            guard case .glyphs(let line, let origin) = item else { return nil }
            return (line, origin)
        }
    }

    private func ink(_ line: CTLine) -> CGRect {
        CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
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
            // `array` needs a column specification this does not read, and
            // `gather` needs page-wide centring the line cannot give it.
            "\\begin{array}{cc} a & b \\end{array}",
            "\\begin{gather} a \\end{gather}",
            "\\begin{pmatrix} a & b",
            "\\begin{pmatrix} a \\end{bmatrix}",
            "\\unknowncommand{x}",
            // A row separator outside an environment has no line to end.
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
        let document = Document(text: "Arrays: $\\begin{array}{cc} a \\end{array}$.")
        let layout = DocumentLayout(
            document: document, theme: Theme(isDark: false), columnWidth: 520)
        let box = try XCTUnwrap(layout.box(at: 0))
        XCTAssertEqual(box.plainText, "Arrays: \\begin{array}{cc} a \\end{array}.")
    }

    func testTheWiderSubsetIsRead() {
        for source in [
            "\\sqrt[3]{8}",
            "\\mathbb{R}^n \\subset \\mathbb{C}",
            "\\mathcal{L}(\\mathfrak{g})",
            "\\mathbf{v} + \\mathit{w} + \\mathsf{s} + \\mathtt{t}",
            "\\hat{x} \\tilde{y} \\dot{z} \\vec{v} \\bar{u} \\overline{AB}",
            "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
            "\\begin{vmatrix} 1 & 0 \\\\ 0 & 1 \\end{vmatrix}",
            "f(x) = \\begin{cases} x^2 & x \\geq 0 \\\\ -x & x < 0 \\end{cases}",
            "\\begin{aligned} a + b &= c \\\\ x &= \\frac{y}{z} \\end{aligned}",
        ] {
            XCTAssertTrue(MathFormula.canTypeset(source), source)
            XCTAssertNotNil(box(source), source)
        }
    }

    /// A blackboard `R` is a character of its own, not a face a font can be
    /// asked for, so the substitution has to happen before layout.
    func testTheAlphabetsBecomeTheirOwnCharacters() {
        XCTAssertEqual(MathSymbols.lettering("RNQZ", style: "mathbb"), "ℝℕℚℤ")
        XCTAssertEqual(MathSymbols.lettering("A", style: "mathbb"), "𝔸")
        XCTAssertEqual(MathSymbols.lettering("L", style: "mathcal"), "ℒ")
        XCTAssertEqual(MathSymbols.lettering("R", style: "mathfrak"), "ℜ")
        // A letter with no such character stays itself rather than becoming
        // something else.
        XCTAssertEqual(MathSymbols.lettering("Ж", style: "mathbb"), "Ж")
    }

    /// A single digit fits in the sign's crook and costs nothing; a wider degree
    /// has nowhere to go but left, and pushes the whole root right.
    func testARootsDegreeSitsInItsCrookUntilItIsTooWide() throws {
        let plain = try XCTUnwrap(box("\\sqrt{8}"))
        let cube = try XCTUnwrap(box("\\sqrt[3]{8}"))
        let tenth = try XCTUnwrap(box("\\sqrt[10]{8}"))
        XCTAssertEqual(cube.width, plain.width, accuracy: 0.01)
        XCTAssertEqual(glyphs(cube).count, glyphs(plain).count + 1)
        XCTAssertGreaterThan(tenth.width, plain.width)
    }

    /// A hat has to sit on the letter's ink. Measuring the font's ascent instead
    /// floats it an x-height clear of what it belongs to.
    func testAnAccentSitsCloseAboveItsLetter() throws {
        let plain = try XCTUnwrap(box("x"))
        let hatted = try XCTUnwrap(box("\\hat{x}"))
        let drawn = glyphs(hatted)
        XCTAssertEqual(drawn.count, 2)
        let letterTop = drawn[0].origin.y - ink(drawn[0].line).maxY
        let markBottom = drawn[1].origin.y - ink(drawn[1].line).minY
        XCTAssertLessThan(markBottom, letterTop)
        XCTAssertGreaterThan(markBottom, letterTop - CTFontGetSize(font) * 0.4)
        // The mark rides inside the line's own ascent, so a paragraph carrying
        // one keeps the leading of a paragraph that does not.
        XCTAssertEqual(hatted.ascent, plain.ascent, accuracy: 0.01)
        XCTAssertEqual(hatted.width, plain.width, accuracy: 0.01)
    }

    /// A macron is one letter wide, so a bar over two letters is a rule.
    func testABarCoversEverythingUnderIt() throws {
        let bar = try XCTUnwrap(box("\\overline{AB}"))
        let rule = try XCTUnwrap(rules(bar).first)
        XCTAssertEqual(rule.width, bar.width, accuracy: 0.01)
        XCTAssertLessThan(rule.maxY, 0)
    }

    func testAMatrixIsTallerThanItsCellsAndHangsEitherSideOfTheAxis() throws {
        let cell = try XCTUnwrap(box("a"))
        let matrix = try XCTUnwrap(box("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"))
        XCTAssertGreaterThan(matrix.ascent, cell.ascent)
        XCTAssertGreaterThan(matrix.descent, cell.descent)
        XCTAssertGreaterThan(matrix.width, cell.width * 2)
    }

    /// `&` in an aligned block is where the lines meet, so the `=` of the second
    /// line stands under the `=` of the first.
    func testAnAlignedBlockLinesItsRowsUpAtTheAmpersand() throws {
        let block = try XCTUnwrap(box("\\begin{aligned} a + b &= c \\\\ x &= y \\end{aligned}"))
        let rows = Dictionary(grouping: glyphs(block).map(\.origin)) { $0.y }
        XCTAssertEqual(rows.count, 2)
        let lefts = rows.values.map { $0.map(\.x).max() ?? 0 }
        // Both rows end at the same place, because both end with one short cell
        // whose column starts at the alignment point.
        XCTAssertEqual(lefts.min() ?? 0, lefts.max() ?? 1, accuracy: 0.01)
    }

    /// `$$\sum_{i=1}^{n}$$` writes its range over and under the sign; `$…$`
    /// keeps it beside, so a paragraph does not grow around one formula.
    func testDisplayStyleMovesTheLimitsOverTheSign() throws {
        let inline = try XCTUnwrap(box("\\sum_{i=1}^{n} i"))
        let display = try XCTUnwrap(displayed("\\sum_{i=1}^{n} i"))
        XCTAssertLessThan(display.width, inline.width)
        XCTAssertGreaterThan(display.ascent + display.descent, inline.ascent + inline.descent)
    }

    /// An integral reads its limits along its own slope, so a book leaves them
    /// beside it even in display style.
    func testAnIntegralKeepsItsLimitsBesideIt() throws {
        let inline = try XCTUnwrap(box("\\int_0^1 x"))
        let display = try XCTUnwrap(displayed("\\int_0^1 x"))
        XCTAssertEqual(display.width, inline.width, accuracy: 0.01)
    }

    func testDisplayFormulasAreMarkedByTheParser() throws {
        let document = Document(text: "$$a$$ and $a$")
        let leaf = try XCTUnwrap(document.leaves.first)
        let parsed = InlineParser.parse(
            content: document.content(of: leaf),
            references: document.references,
            documentBytes: document.bytes,
            footnotes: document.footnotes
        )
        let formulas = parsed.runs.filter { $0.style.contains(.math) }
        XCTAssertEqual(formulas.count, 2)
        XCTAssertTrue(formulas[0].style.contains(.displayMath))
        XCTAssertFalse(formulas[1].style.contains(.displayMath))
    }
}
