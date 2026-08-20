import AppKit
import XCTest

@testable import MarkioRender

/// Every word in every kind of diagram, measured against whatever was painted
/// under it.
///
/// The palette was chosen against WCAG once, and that says nothing about a
/// colour an author wrote: `style A fill:#111` arrives with the theme's dark
/// ink still on top of it, and the label goes out at 1.02:1 — present in the
/// picture, invisible on the screen. One kind of diagram was found that way and
/// fixed; this walks all of them, so the next one is found by a test rather
/// than by a reader.
@MainActor
final class DiagramLegibilityTests: XCTestCase {
    /// WCAG 2.1 relative luminance and contrast ratio, written out here rather
    /// than borrowed from the layout: a test that shares its arithmetic with
    /// what it checks agrees with it whatever either of them says.
    private func contrast(_ one: CGColor, _ other: CGColor) -> CGFloat {
        func luminance(_ color: CGColor) -> CGFloat {
            let parts = srgb(color).prefix(3).map { part -> CGFloat in
                part <= 0.03928 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
        }
        let one = luminance(one)
        let other = luminance(other)
        return (max(one, other) + 0.05) / (min(one, other) + 0.05)
    }

    private func srgb(_ color: CGColor) -> [CGFloat] {
        let converted =
            color.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
            ?? color
        let parts = converted.components ?? [0, 0, 0, 1]
        return [parts[0], parts[1], parts[2], converted.alpha]
    }

    /// A colour with alpha, over what is already there. The layout paints a
    /// group, a section band and a treemap tile at part strength, so the shade
    /// a word is actually read against is a mix and not the colour named.
    private func over(_ top: CGColor, _ under: CGColor) -> CGColor {
        let top = srgb(top)
        let under = srgb(under)
        let alpha = top[3]
        guard alpha < 1 else {
            return CGColor(srgbRed: top[0], green: top[1], blue: top[2], alpha: 1)
        }
        return CGColor(
            srgbRed: top[0] * alpha + under[0] * (1 - alpha),
            green: top[1] * alpha + under[1] * (1 - alpha),
            blue: top[2] * alpha + under[2] * (1 - alpha), alpha: 1)
    }

    private func inkOf(_ line: CTLine) -> CGColor? {
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
        guard
            let colour = (CTRunGetAttributes(run) as NSDictionary)[kCTForegroundColorAttributeName]
        else { return nil }
        return (colour as! CGColor)
    }

    /// The faintest word in a picture, and what it is written on.
    private func faintest(_ source: String, dark: Bool = false) throws -> (
        ratio: CGFloat, ink: CGColor, on: CGColor, words: Int
    ) {
        let diagram = try XCTUnwrap(MermaidDiagram.parse(source), "did not parse")
        let theme = Theme(isDark: dark)
        let drawing = MermaidLayout.draw(diagram, theme: theme, width: 900)
        let page = theme.forDiagrams.palette.codeBackground
        var worst = (ratio: CGFloat.greatestFiniteMagnitude, ink: page, on: page)
        var words = 0
        for decoration in drawing.decorations {
            guard case .glyphs(let line, let origin) = decoration, let ink = inkOf(line) else {
                continue
            }
            words += 1
            var ascent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
            // The middle of the word rather than its baseline corner, which on
            // a short word can fall outside the shape the word sits in.
            let point = CGPoint(x: origin.x + width / 2, y: origin.y - ascent / 2)
            var behind = page
            for painted in drawing.decorations {
                switch painted {
                case .path(let path, let colour, _, true) where path.contains(point):
                    behind = over(colour, behind)
                case .fill(let rect, let colour, _) where rect.contains(point):
                    behind = over(colour, behind)
                default: break
                }
            }
            let ratio = contrast(ink, behind)
            if ratio < worst.ratio { worst = (ratio, ink, behind) }
        }
        XCTAssertGreaterThan(words, 0, "nothing was written in this diagram")
        return (worst.ratio, worst.ink, worst.on, words)
    }

    private func hex(_ colour: CGColor) -> String {
        srgb(colour).prefix(3).map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    private func assertReadable(
        _ source: String, _ name: String, dark: Bool = false, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let worst = try faintest(source, dark: dark)
        XCTAssertGreaterThanOrEqual(
            worst.ratio, MermaidLayout.readableContrast - 0.01,
            "\(name): \(hex(worst.ink)) on \(hex(worst.on))", file: file, line: line)
    }

    /// One sample of every kind the layout draws, in the colours the theme
    /// picks for it.
    func testEveryKindOfDiagramIsWrittenInInkThatReads() throws {
        let kinds: [(String, String)] = [
            ("flowchart", "flowchart TD\n A[Start] --> B{Choice}\n B -->|yes| C[Finish]"),
            ("sequence", "sequenceDiagram\n box Group\n participant A\n end\n A->>B: hello"),
            ("class", "classDiagram\n class Cat {\n +String name\n +walk()\n }\n Cat <|-- Dog"),
            ("state", "stateDiagram-v2\n [*] --> Idle\n Idle --> Busy : work"),
            ("er", "erDiagram\n CUSTOMER ||--o{ ORDER : places"),
            ("pie", "pie title Share\n \"One\" : 40\n \"Two\" : 60"),
            ("mindmap", "mindmap\n root((Core))\n  Branch one\n   Leaf\n  Branch two"),
            ("timeline", "timeline\n title History\n section Early\n 1990 : first\n 1995 : second"),
            ("journey", "journey\n title Day\n section Morning\n Wake: 3: Me\n Eat: 5: Me, You"),
            (
                "gantt",
                "gantt\n title Plan\n dateFormat YYYY-MM-DD\n section Work\n One :a1, 2024-01-01, 3d\n Two :after a1, 2d"
            ),
            (
                "quadrant",
                "quadrantChart\n title Q\n x-axis Low --> High\n y-axis Bad --> Good\n quadrant-1 Do\n quadrant-2 Plan\n quadrant-3 Drop\n quadrant-4 Later\n A: [0.3, 0.6]"
            ),
            (
                "xy",
                "xychart-beta\n title Sales\n x-axis [jan, feb, mar]\n y-axis \"Revenue\" 0 --> 30\n bar [10, 20, 15]"
            ),
            ("git", "gitGraph\n commit\n branch feature\n commit\n checkout main\n merge feature"),
            ("git down", "gitGraph TB:\n commit\n branch feature\n commit"),
            ("packet", "packet-beta\n 0-15: \"Source Port\"\n 16-31: \"Target Port\""),
            ("kanban", "kanban\n Todo\n  [One]\n Doing\n  [Two]"),
            ("sankey", "sankey-beta\n A,B,10\n B,C,5"),
            ("treemap", "treemap-beta\n\"Main\"\n    \"A\": 20\n    \"B\": 10"),
            (
                "architecture",
                "architecture-beta\n group api(cloud)[API]\n service db(database)[Store] in api"
            ),
            ("radar", "radar-beta\n axis a[\"One\"], b[\"Two\"]\n curve x[\"Now\"]{1, 2}"),
            ("block", "block-beta\n columns 2\n A[\"One\"] B[\"Two\"]"),
        ]
        for (name, source) in kinds {
            try assertReadable(source, name)
            try assertReadable(source, "\(name) on a dark page", dark: true)
        }
    }

    /// The same, for colours the author wrote. Mermaid hands `style` and
    /// `classDef` straight through, so these are the ones that used to come out
    /// unreadable.
    func testAFillAnAuthorChoseIsWashedUntilTheLabelOnItReads() throws {
        let written: [(String, String)] = [
            ("node fill", "flowchart TD\n A[Start] --> B[End]\n style A fill:#111"),
            (
                "classDef",
                "flowchart TD\n A[Start] --> B[End]\n classDef hot fill:#c0392b\n class A hot"
            ),
            (
                "subgraph fill",
                "flowchart TD\n subgraph g[Group]\n A[Start]\n end\n A --> B[End]\n style g fill:#111"
            ),
            (
                "state fill",
                "stateDiagram-v2\n [*] --> Idle\n classDef hot fill:#111\n class Idle hot"
            ),
            ("class fill", "classDiagram\n class Cat\n style Cat fill:#111"),
            (
                "entity fill",
                "erDiagram\n CUSTOMER ||--o{ ORDER : places\n style CUSTOMER fill:#111"
            ),
            (
                "treemap class",
                "treemap-beta\n\"Main\"\n    \"A\": 20\n    \"B\": 10:::hot\n\nclassDef hot fill:#111;"
            ),
            (
                "sequence box",
                "sequenceDiagram\n box rgb(17,17,17) Dark\n participant A\n end\n A->>B: hi"
            ),
        ]
        for (name, source) in written {
            try assertReadable(source, name)
            try assertReadable(source, "\(name) on a dark page", dark: true)
        }
    }

    /// An author who wrote both halves of the pair has already answered the
    /// question, and washing the fill would erase their answer along with their
    /// words: pale lettering on a dark node stays exactly as written.
    func testAFillWrittenWithItsOwnLetteringIsLeftAlone() throws {
        let theme = Theme(isDark: false).forDiagrams
        let dark = CGColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        let pale = CGColor(gray: 1, alpha: 1)
        XCTAssertEqual(
            MermaidLayout.wash(dark, on: theme.palette.codeBackground, under: pale), dark)
        let worst = try faintest(
            "flowchart TD\n A[Start] --> B[End]\n style A fill:#111,color:#fff")
        XCTAssertGreaterThan(worst.ratio, 15)
    }
}
