import XCTest

@testable import Markio

/// Guards the public claim "all Mermaid 11 diagram types render": every fence
/// below must produce an SVG through the real engine (template.html + the
/// vendored mermaid bundle). A vendor upgrade that drops or breaks a type
/// fails here before the claim goes stale. ZenUML is an external plugin and
/// is deliberately absent. [REF:fr:mermaid-zoom]
@MainActor
final class MermaidDiagramTypesTests: XCTestCase {
    /// One minimal, valid source per built-in diagram type of mermaid 11.6.
    private static let sources: [String: String] = [
        "flowchart": "flowchart LR\n  A --> B",
        "sequence": "sequenceDiagram\n  Alice->>Bob: Hi",
        "class": "classDiagram\n  class Animal",
        "state": "stateDiagram-v2\n  [*] --> Idle",
        "er": "erDiagram\n  USER ||--o{ ORDER : places",
        "journey": "journey\n  title T\n  section S\n    Do: 5: Me",
        "gantt": "gantt\n  title T\n  dateFormat YYYY-MM-DD\n  section S\n  A :a1, 2026-01-01, 3d",
        "pie": "pie title P\n  \"A\" : 1",
        "quadrant": "quadrantChart\n  title Q\n  x-axis Low --> High\n  y-axis Slow --> Fast\n  A: [0.5, 0.5]",
        "requirement": "requirementDiagram\n  requirement r {\n  id: 1\n  text: t\n  }",
        "gitgraph": "gitGraph\n  commit",
        "c4": "C4Context\n  Person(u, \"User\")",
        "mindmap": "mindmap\n  root((m))",
        "timeline": "timeline\n  title T\n  2026 : done",
        "sankey": "sankey-beta\n  A,B,10",
        "xychart": "xychart-beta\n  x-axis [a, b]\n  y-axis \"y\" 0 --> 10\n  bar [5, 9]",
        "block": "block-beta\n  a b",
        "packet": "packet-beta\n  0-15: \"Field\"",
        "kanban": "kanban\n  todo\n    t[Task]",
        "architecture": "architecture-beta\n  group api(cloud)[API]",
        "radar": "radar-beta\n  axis a, b, c\n  curve x{1, 2, 3}",
    ]

    func testAllBuiltInDiagramTypesRenderToSVG() async throws {
        let document = Self.sources
            .sorted { $0.key < $1.key }
            .map { "## \($0.key)\n\n```mermaid\n\($0.value)\n```" }
            .joined(separator: "\n\n")

        let preview = PreviewController()
        try await preview.loadTemplate()
        await preview.render(document)

        let total = try await count(preview, "document.querySelectorAll('pre.mermaid').length")
        XCTAssertEqual(total, Self.sources.count, "Sanity: every fence must reach the page")

        // A fence whose source fails to parse keeps its text and gets no SVG.
        // Count fences that carry at least one SVG, not descendant SVGs — some
        // types (architecture icons) nest several SVGs inside one diagram.
        let rendered = try await count(
            preview,
            "Array.from(document.querySelectorAll('pre.mermaid'))"
                + ".filter(function (p) { return p.querySelector('svg'); }).length")
        if rendered != Self.sources.count {
            let failed = try await preview.evaluate(
                "Array.from(document.querySelectorAll('pre.mermaid'))"
                    + ".filter(function (p) { return !p.querySelector('svg'); })"
                    + ".map(function (p) { return (p.dataset.markioSrc || '').split('\\n')[0]; })"
                    + ".join(', ')")
            XCTFail("Diagram types failed to render: \(failed ?? "?")")
        }
    }
}
