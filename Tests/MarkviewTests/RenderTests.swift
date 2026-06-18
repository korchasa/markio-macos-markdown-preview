import XCTest

@testable import Markview

/// Exercises the real vendored pipeline (markdown-it + task-lists + highlight.js
/// + mermaid) inside a `WKWebView`. [REF:fr:gfm] [REF:fr:mermaid] [REF:fr:highlight]
@MainActor
final class RenderTests: XCTestCase {
    func testGFMTableAndTaskList() async throws {
        let preview = try await makeLoadedPreview()
        let markdown = """
            | A | B |
            | --- | --- |
            | 1 | 2 |

            - [ ] todo
            - [x] done
            """
        await preview.render(markdown)

        let tables = try await count(preview, "document.querySelectorAll('#content table').length")
        XCTAssertGreaterThanOrEqual(tables, 1, "GFM table should render as a <table>")

        let checkboxes = try await count(
            preview, "document.querySelectorAll('#content .task-list-item-checkbox').length")
        XCTAssertEqual(checkboxes, 2, "Each task-list item should render a checkbox")

        let checked = try await count(
            preview,
            "document.querySelectorAll('#content .task-list-item-checkbox[checked]').length")
        XCTAssertEqual(checked, 1, "Only the [x] item should be checked")
    }

    func testMermaidFlowchartRenders() async throws {
        let preview = try await makeLoadedPreview()
        let markdown = """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """
        await preview.render(markdown)

        let svgs = try await count(
            preview, "document.querySelectorAll('#content pre.mermaid svg').length")
        XCTAssertGreaterThanOrEqual(svgs, 1, "Mermaid block should render an SVG diagram")
    }

    func testCodeBlockHighlighted() async throws {
        let preview = try await makeLoadedPreview()
        let markdown = """
            ```swift
            let answer = 42
            print(answer)
            ```
            """
        await preview.render(markdown)

        let pre = try await count(preview, "document.querySelectorAll('#content pre.hljs').length")
        XCTAssertGreaterThanOrEqual(pre, 1, "Code block should be wrapped for highlighting")

        let tokens = try await count(
            preview,
            "document.querySelectorAll('#content pre.hljs code span[class^=\"hljs-\"]').length")
        XCTAssertGreaterThanOrEqual(tokens, 1, "Highlighted code should contain token spans")
    }

    /// NFR Reliability: malformed Markdown renders best-effort and never crashes.
    func testMalformedMarkdownDoesNotCrash() async throws {
        let preview = try await makeLoadedPreview()
        let inputs = [
            "",
            "```mermaid\nnot a valid diagram (((\n```",
            String(repeating: "> ", count: 5000) + "deeply nested",
            "| broken | table\n| --- \n| 1",
            "<script>alert(1)</script> & <unclosed",
        ]
        for input in inputs {
            await preview.render(input)  // render() is best-effort and never throws
        }
        let hasContent = try await count(preview, "document.getElementById('content') ? 1 : 0")
        XCTAssertEqual(hasContent, 1, "Render surface must survive every malformed input")
    }

    /// NFR Scale: a multi-MB document renders without hanging the pipeline.
    func testRendersLargeDocumentWithoutHanging() async throws {
        let preview = try await makeLoadedPreview()
        let large = String(repeating: "# Heading\n\nLorem ipsum dolor sit amet.\n\n", count: 30_000)
        await preview.render(large)  // ~1.2 MB
        let paragraphs = try await count(preview, "document.querySelectorAll('#content p').length")
        XCTAssertGreaterThan(paragraphs, 0, "Large document should render content")
    }
}
