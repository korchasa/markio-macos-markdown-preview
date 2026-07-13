import XCTest

@testable import Markio

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

    /// Inline `$…$` and block `$$…$$` LaTeX render as KaTeX; money `$` stays
    /// literal; malformed math never crashes the render. [REF:fr:math]
    func testMathRendersWithKatex() async throws {
        let preview = try await makeLoadedPreview()

        // Inline + block math both render to KaTeX DOM nodes. The block uses the
        // multi-line `$$` form (delimiters on their own lines) so the block rule's
        // multi-line scan path is exercised, not just the single-line shortcut.
        await preview.render(
            "Inline $E = mc^2$ and block:\n\n$$\n\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}\n$$"
        )
        let katex = try await count(preview, "document.querySelectorAll('#content .katex').length")
        XCTAssertGreaterThanOrEqual(katex, 2, "Inline and block math should both render as KaTeX")
        // KaTeX's default output is htmlAndMathml; the sanitize gate must
        // preserve the MathML branch, not just the HTML spans. [REF:fr:inline-html]
        let mathml = try await count(
            preview, "document.querySelectorAll('#content .katex-mathml math').length")
        XCTAssertGreaterThanOrEqual(mathml, 1, "KaTeX MathML branch must survive sanitization")
        let display = try await count(
            preview, "document.querySelectorAll('#content .katex-display').length")
        XCTAssertGreaterThanOrEqual(display, 1, "Block `$$…$$` should render as display math")

        // Money guard: `$5 and $10` must stay literal text, not become math.
        await preview.render("Pay $5 and $10 today.")
        let money = try await count(preview, "document.querySelectorAll('#content .katex').length")
        XCTAssertEqual(money, 0, "Dollar amounts must not be parsed as math")

        // Malformed math renders best-effort and never crashes the surface.
        await preview.render("Broken $\\frac{$ math")
        let hasContent = try await count(preview, "document.getElementById('content') ? 1 : 0")
        XCTAssertEqual(hasContent, 1, "Malformed math must not destroy the render surface")
    }

    /// Leading YAML frontmatter renders as a distinct highlighted metadata block;
    /// a `---` anywhere but the document start stays a normal thematic break; a
    /// document with no frontmatter is unchanged. [REF:fr:frontmatter]
    func testFrontmatterRendersAsMetadata() async throws {
        let preview = try await makeLoadedPreview()

        // Leading frontmatter → a highlighted YAML box, body still parses.
        await preview.render("---\ntitle: Hello\ntags: [a, b]\n---\n\n# Body")
        let fm = try await count(
            preview, "document.querySelectorAll('#content pre.markio-frontmatter').length")
        XCTAssertGreaterThanOrEqual(fm, 1, "Leading frontmatter should render as a metadata block")
        let tokens = try await count(
            preview,
            "document.querySelectorAll('#content pre.markio-frontmatter span[class^=\"hljs-\"]').length"
        )
        XCTAssertGreaterThanOrEqual(tokens, 1, "Frontmatter YAML should be syntax-highlighted")
        let bodyHeadings = try await count(
            preview, "document.querySelectorAll('#content h1').length")
        XCTAssertGreaterThanOrEqual(
            bodyHeadings, 1, "Body after frontmatter must render as Markdown")

        // A `---` mid-document is NOT frontmatter; the block is doc-start-only.
        await preview.render("# Body\n\n---\ntitle: x\n---")
        let midFm = try await count(
            preview, "document.querySelectorAll('#content pre.markio-frontmatter').length")
        XCTAssertEqual(midFm, 0, "A `---` block mid-document must not be treated as frontmatter")

        // A plain `---` after a blank line stays a thematic break.
        await preview.render("Text\n\n---\n\nMore")
        let rules = try await count(preview, "document.querySelectorAll('#content hr').length")
        XCTAssertGreaterThanOrEqual(
            rules, 1, "A standalone `---` must still render a horizontal rule")
        let noFm = try await count(
            preview, "document.querySelectorAll('#content pre.markio-frontmatter').length")
        XCTAssertEqual(noFm, 0, "Plain document must have no frontmatter block")
    }

    /// Raw inline HTML renders as real elements (GitHub parity): a `<table>`
    /// with `rowspan`/`colspan` — inexpressible as a GFM pipe table — must
    /// become a real table, not escaped literal text. [REF:fr:inline-html]
    func testInlineHTMLTableRenders() async throws {
        let preview = try await makeLoadedPreview()
        let markdown = """
            Intro paragraph.

            <table>
            <thead>
            <tr><th rowspan="2">Primitive</th><th colspan="2">Quality</th></tr>
            <tr><th>Claude Code</th><th>Codex</th></tr>
            </thead>
            <tbody>
            <tr><td><code>.claude/agents</code></td><td>Full</td><td>Archive</td></tr>
            </tbody>
            </table>
            """
        await preview.render(markdown)

        let tables = try await count(preview, "document.querySelectorAll('#content table').length")
        XCTAssertGreaterThanOrEqual(tables, 1, "Raw HTML table should render as a <table>")

        let rowspans = try await count(
            preview, "document.querySelectorAll('#content th[rowspan]').length")
        XCTAssertGreaterThanOrEqual(rowspans, 1, "rowspan attribute must survive the allowlist")

        let cellCode = try await count(
            preview, "document.querySelectorAll('#content td code').length")
        XCTAssertGreaterThanOrEqual(cellCode, 1, "Inline <code> inside cells must survive")

        let escapedText = try await count(
            preview,
            "document.getElementById('content').textContent.indexOf('<table>') === -1 ? 1 : 0")
        XCTAssertEqual(escapedText, 1, "Raw HTML must not appear as escaped literal text")
    }

    /// Dangerous raw HTML is stripped by the sanitizer before DOM insertion and
    /// never executes — not merely escaped. [REF:fr:inline-html]
    func testInlineHTMLSanitized() async throws {
        let preview = try await makeLoadedPreview()
        let markdown = """
            <script>window.__xss = 1</script>

            <img src="x" onerror="window.__xss = 1">

            <a href="javascript:alert(1)">click</a>

            <style>body { display: none }</style>
            """
        await preview.render(markdown)

        let scripts = try await count(
            preview, "document.querySelectorAll('#content script, #content style').length")
        XCTAssertEqual(scripts, 0, "script/style elements must be stripped")

        let handlers = try await count(
            preview, "document.querySelectorAll('#content [onerror], #content [onclick]').length")
        XCTAssertEqual(handlers, 0, "Event-handler attributes must be stripped")

        let jsLinks = try await count(
            preview, "document.querySelectorAll('#content a[href^=\"javascript:\"]').length")
        XCTAssertEqual(jsLinks, 0, "javascript: URLs must be stripped")

        let executed = try await count(
            preview, "typeof window.__xss === 'undefined' ? 1 : 0")
        XCTAssertEqual(executed, 1, "No injected handler may have executed")
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
            "```swift\nlet unterminated = true",  // unclosed fence [REF:fr:code-copy]
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
